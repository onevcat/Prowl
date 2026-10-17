import Foundation

/// The remote process probe (docs-ai 082, C6): a POSIX `sh` script that Prowl pipes to
/// `sh -s` over its side channel. It installs nothing and reads only the process table,
/// so the host needs no Prowl file, configuration, or hook. `RemoteProbeParser` reads
/// its output; the format is described in the script header.
nonisolated enum RemoteProbeScript {
  static let text = #"""
    # Prowl remote probe (docs-ai 082, C6). POSIX sh, piped to `sh -s`; installs nothing.
    #
    # Output: one record per line, fields separated by TAB, each field escaped
    # (% -> %25, TAB -> %09, LF -> %0A, CR -> %0D). Records:
    #   PROWL-PROBE <format>
    #   H <os> <boot id>
    #   S <pane|-> <anchor pid> <tty> <tpgid>        an SSH session with a terminal
    #   P <pane|-> <pid> <ppid> <pgid> <start> <elapsed s> <comm> <argv mode> <argv>
    #                                                a member of its foreground job;
    #                                                argv mode v = US-separated vector,
    #                                                s = one space-joined string
    #   D <pane|-> <pid> <cwd>
    #   END <S count> <P count>
    # A snapshot without END is incomplete.
    LC_ALL=C
    export LC_ALL
    uid=$(id -u)
    echo "PROWL-PROBE	1"

    if [ -r /proc/self/stat ]; then
      boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
      echo "H	Linux	${boot:--}"
      files=
      for d in /proc/[0-9]*; do
        [ -O "$d" ] && files="$files $d/stat"
      done
      hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
      up=$(cut -d' ' -f1 /proc/uptime)
      # shellcheck disable=SC2086
      table=$(cat $files 2>/dev/null | awk '
        {
          line = $0
          open = index(line, "(")
          rest = line; sub(/^.*\) /, "", rest)
          comm = substr(line, open + 1, length(line) - length(rest) - open - 2)
          split(rest, f, " ")
          # pid ppid pgrp tpgid starttime comm
          printf "%s %s %s %s %s %s\n", substr(line, 1, open - 2), f[2], f[3], f[6], f[20], comm
        }')
      anchors=$(printf '%s\n' "$table" | awk '
        { pid[$1] = $1; ppid[$1] = $2; comm[$1] = $6; tpgid[$1] = $4 }
        END {
          for (p in pid) {
            c = comm[ppid[p]]
            if ((c == "sshd-session" || c == "sshd") && tpgid[p] > 0) print p, tpgid[p]
          }
        }')
      scount=0
      pcount=0
      for a in $(printf '%s\n' "$anchors" | awk 'NF == 2 { print $1 ":" $2 }'); do
        apid=${a%%:*}
        tpgid=${a#*:}
        pane=$(tr '\0' '\n' 2>/dev/null < "/proc/$apid/environ" | sed -n 's/^LC_PROWL_PANE=//p' | head -n 1)
        tty=$(readlink "/proc/$apid/fd/0" 2>/dev/null)
        printf 'S\t%s\t%s\t%s\t%s\n' "${pane:--}" "$apid" "${tty:--}" "$tpgid"
        scount=$((scount + 1))
        for m in $(printf '%s\n' "$table" | awk -v g="$tpgid" '$3 == g { print $1 }'); do
          argv=$(tr '\0' '\037' 2>/dev/null < "/proc/$m/cmdline")
          cwd=$(readlink "/proc/$m/cwd" 2>/dev/null)
          printf '%s\n' "$table" | awk -v m="$m" -v pane="${pane:--}" -v up="$up" -v hz="$hz" \
            -v argv="$argv" -v cwd="$cwd" '
            function esc(s) {
              gsub(/%/, "%25", s); gsub(/\t/, "%09", s); gsub(/\n/, "%0A", s); gsub(/\r/, "%0D", s); return s
            }
            $1 == m {
              comm = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", comm)
              sub(/\037$/, "", argv)
              printf "P\t%s\t%s\t%s\t%s\t%s\t%d\t%s\tv\t%s\n", \
                esc(pane), $1, $2, $3, $5, up - $5 / hz, esc(comm), esc(argv)
              if (cwd != "") printf "D\t%s\t%s\t%s\n", esc(pane), $1, esc(cwd)
            }'
          pcount=$((pcount + 1))
        done
      done
      printf 'END\t%s\t%s\n' "$scount" "$pcount"
      exit 0
    fi

    # macOS: the environment of platform binaries (the /bin/zsh login shell) is
    # hidden, so the anchor is "parent is sshd-session with a terminal" and the pane
    # id comes from the foreground job's own environment.
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\), usec = \([0-9]*\) }.*/\1.\2/p')
    echo "H	Darwin	${boot:--}"
    names=$(ps -A -o pid=,ucomm=)
    table=$(ps -A -ww -o pid=,ppid=,pgid=,tpgid=,uid=,tty=,etime=,lstart=,args=)
    members=$(printf '%s\n' "$table" | awk -v uid="$uid" '
      { pid = $1; ppid[pid] = $2; tpgid[pid] = $4; owner[pid] = $5; tty[pid] = $6; pgid[pid] = $3
        a = $0; for (i = 1; i <= 12; i++) sub(/^ *[^ ]+/, "", a); sub(/^ +/, "", a); args[pid] = a }
      END {
        for (p in ppid) {
          if (owner[p] != uid || tty[p] == "??") continue
          if (args[ppid[p]] !~ /^sshd(-session)?: /) continue
          for (m in ppid) if (pgid[m] == tpgid[p] && tty[m] == tty[p]) print p, tpgid[p], tty[p], m
        }
      }')
    pids=$(printf '%s\n' "$members" | awk 'NF { printf "%s%s", sep, $4; sep = "," }')
    envs=
    cwds=
    if [ -n "$pids" ]; then
      envs=$(ps -wwE -o pid=,command= -p "$pids" 2>/dev/null | awk '
        { v = "-"
          for (i = 2; i <= NF; i++) if ($i ~ /^LC_PROWL_PANE=/) { v = substr($i, 15); break }
          print $1, v }')
      cwds=$(lsof -a -d cwd -Fpn -p "$pids" 2>/dev/null)
    fi
    {
      printf '%s\n' "$names" | sed 's/^/N /'
      printf '%s\n' "$table" | sed 's/^/T /'
      printf '%s\n' "$envs" | sed 's/^/V /'
      printf '%s\n' "$cwds" | sed 's/^/W /'
      printf '%s\n' "$members" | sed 's/^/M /'
    } | awk '
      function esc(s) {
        gsub(/%/, "%25", s); gsub(/\t/, "%09", s); gsub(/\n/, "%0A", s); gsub(/\r/, "%0D", s); return s
      }
      function seconds(e,   n, a, s, d, x, i) {
        d = 0; if (e ~ /-/) { split(e, x, "-"); d = x[1]; e = x[2] }
        n = split(e, a, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + a[i]
        return s + d * 86400
      }
      $1 == "N" { p = $2; c = $0; sub(/^N +[0-9]+ /, "", c); sub(/ +$/, "", c); name[p] = c; next }
      $1 == "T" {
        p = $2; ppid[p] = $3; pgid[p] = $4; et[p] = $8
        start[p] = $9 " " $10 " " $11 " " $12 " " $13
        a = $0; for (i = 1; i <= 13; i++) sub(/^ *[^ ]+/, "", a); sub(/^ +/, "", a); args[p] = a
        next
      }
      $1 == "V" { pane[$2] = $3; next }
      $1 == "W" {
        if ($2 ~ /^p/) wp = substr($2, 2)
        else if ($2 ~ /^n/) { c = $0; sub(/^W n/, "", c); cwd[wp] = c }
        next
      }
      $1 == "M" && NF == 5 {
        a = $2; m = $5
        if (!(a in seen)) { order[++na] = a; seen[a] = 1; tg[a] = $3; tt[a] = $4 }
        mem[a] = mem[a] " " m
        if (pane[m] != "" && pane[m] != "-") apane[a] = pane[m]
        next
      }
      END {
        pc = 0
        for (i = 1; i <= na; i++) {
          a = order[i]; pn = (a in apane) ? apane[a] : "-"
          printf "S\t%s\t%s\t/dev/%s\t%s\n", esc(pn), a, tt[a], tg[a]
          n = split(mem[a], ms, " ")
          for (j = 1; j <= n; j++) {
            m = ms[j]
            printf "P\t%s\t%s\t%s\t%s\t%s\t%d\t%s\ts\t%s\n", \
              esc(pn), m, ppid[m], pgid[m], esc(start[m]), seconds(et[m]), esc(name[m]), esc(args[m])
            if (m in cwd) printf "D\t%s\t%s\t%s\n", esc(pn), m, esc(cwd[m])
            pc++
          }
        }
        printf "END\t%d\t%d\n", na, pc
      }'

    """#
}
