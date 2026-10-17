import Foundation

/// The remote process probe (docs-ai 082, C6): a POSIX `sh` script that Prowl pipes to
/// `sh -s` over its side channel. It installs nothing; it reads the process table and, for
/// a tmux client in a session's foreground, asks that client's tmux server for its active
/// pane and visible screen. The host needs no Prowl file, configuration, or hook. `RemoteProbeParser` reads
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
    #   D <pane|-> <pid> <r|l> <cwd>                 r = raw bytes, l = lsof's escaped
    #                                                display form (macOS)
    #   X <pane|-> <anchor pid> <client pid> <tmux pane> <pane tty> <in mode> <tpgid>
    #                                                a tmux client in that session's
    #                                                foreground, and its active pane
    #   Y, Z                                         as P and D, for that pane's
    #                                                foreground job
    #   C <pane|-> <truncated 0|1> <text>            that pane's visible screen
    #   END <S count> <P count> <X count> <Y count>
    # A snapshot without END is incomplete.
    LC_ALL=C
    export LC_ALL
    uid=$(id -u)
    cap=65536
    echo "PROWL-PROBE	2"
    clients=

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
      # member <record> <pane> <pid>: one P or Y record, with its D or Z record.
      member() {
        # The trailing x keeps trailing newlines that command substitution would strip.
        argv=$(tr '\0' '\037' 2>/dev/null < "/proc/$3/cmdline"; printf x)
        argv=${argv%x}
        cwd=$(readlink "/proc/$3/cwd" 2>/dev/null && printf x)
        [ -n "$cwd" ] && cwd=${cwd%?x}
        # Untrusted strings reach awk through ENVIRON: `-v` would decode backslash escapes.
        printf '%s\n' "$table" | PROWL_PANE="$2" PROWL_ARGV="$argv" PROWL_CWD="$cwd" \
          awk -v m="$3" -v up="$up" -v hz="$hz" -v rec="$1" '
          function esc(s) {
            gsub(/%/, "%25", s); gsub(/\t/, "%09", s); gsub(/\n/, "%0A", s); gsub(/\r/, "%0D", s); return s
          }
          $1 == m {
            pane = ENVIRON["PROWL_PANE"]; argv = ENVIRON["PROWL_ARGV"]; cwd = ENVIRON["PROWL_CWD"]
            comm = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", comm)
            sub(/\037$/, "", argv)
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\tv\t%s\n", \
              rec, esc(pane), $1, $2, $3, $5, up - $5 / hz, esc(comm), esc(argv)
            if (cwd != "") printf "%s\t%s\t%s\tr\t%s\n", (rec == "P" ? "D" : "Z"), esc(pane), $1, esc(cwd)
          }'
      }
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
          member P "${pane:--}" "$m"
          pcount=$((pcount + 1))
          # tmux renames its client `tmux: client` on Linux.
          comm=$(printf '%s\n' "$table" | awk -v m="$m" '$1 == m { sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ /, ""); print }')
          case "$comm" in
            tmux | "tmux: client")
              clients="$clients$apid ${pane:--} $m $(readlink "/proc/$m/exe" 2>/dev/null)
    "
              ;;
          esac
        done
      done
      # pane_job <tpgid> <tty>: the members of a tmux pane's foreground job.
      pane_job() {
        printf '%s\n' "$table" | awk -v g="$1" '$3 == g { print $1 }'
      }
      pane_tpgid() {
        printf '%s\n' "$table" | awk -v p="$1" '$1 == p { print $4 }'
      }
    else
      # macOS: the environment of platform binaries (the /bin/zsh login shell) is
      # hidden, so the anchor is "parent is sshd-session with a terminal" and the pane
      # id comes from the foreground job's own environment.
      boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\), usec = \([0-9]*\) }.*/\1.\2/p')
      echo "H	Darwin	${boot:--}"
      names=$(ps -A -o pid=,ucomm=)
      table=$(ps -A -ww -o pid=,ppid=,pgid=,tpgid=,uid=,tty=,etime=,lstart=,args=)
      # render <record> <M lines>: S (for P only), P or Y, and D or Z records; for P it also
      # prints "#COUNT <S> <P>" and "#TMUX <anchor> <pane> <pid>" for tmux clients.
      render() {
        rpids=$(printf '%s\n' "$2" | awk 'NF { printf "%s%s", sep, $4; sep = "," }')
        envs=
        cwds=
        if [ -n "$rpids" ]; then
          envs=$(ps -wwE -o pid=,command= -p "$rpids" 2>/dev/null | awk '
            { v = "-"
              for (i = 2; i <= NF; i++) if ($i ~ /^LC_PROWL_PANE=/) { v = substr($i, 15); break }
              print $1, v }')
          cwds=$(lsof -a -d cwd -Fpn -p "$rpids" 2>/dev/null)
        fi
        {
          printf '%s\n' "$names" | sed 's/^/N /'
          printf '%s\n' "$table" | sed 's/^/T /'
          printf '%s\n' "$envs" | sed 's/^/V /'
          printf '%s\n' "$cwds" | sed 's/^/W /'
          printf '%s\n' "$2" | sed 's/^/M /'
        } | awk -v rec="$1" '
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
              if (rec == "P") printf "S\t%s\t%s\t/dev/%s\t%s\n", esc(pn), a, tt[a], tg[a]
              if (rec == "Y") pn = a
              n = split(mem[a], ms, " ")
              for (j = 1; j <= n; j++) {
                m = ms[j]
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\ts\t%s\n", \
                  rec, esc(pn), m, ppid[m], pgid[m], esc(start[m]), seconds(et[m]), esc(name[m]), esc(args[m])
                if (m in cwd) printf "%s\t%s\t%s\tl\t%s\n", (rec == "P" ? "D" : "Z"), esc(pn), m, esc(cwd[m])
                if (rec == "P" && name[m] == "tmux") printf "#TMUX %s %s %s\n", a, pn, m
                pc++
              }
            }
            if (rec == "P") printf "#COUNT %d %d\n", na, pc
          }'
      }
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
      body=$(render P "$members")
      printf '%s\n' "$body" | grep -v '^#' | grep -v '^$'
      set -- $(printf '%s\n' "$body" | sed -n 's/^#COUNT //p')
      scount=${1:-0}
      pcount=${2:-0}
      for c in $(printf '%s\n' "$body" | sed -n 's/^#TMUX \([^ ]*\) \([^ ]*\) \([^ ]*\)$/\1:\2:\3/p'); do
        exe=$(lsof -a -p "${c##*:}" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
        clients="$clients$(printf '%s' "$c" | tr ':' ' ') $exe
    "
      done
      # pane_job <tpgid> <tty>: the members of a tmux pane's foreground job.
      pane_job() {
        printf '%s\n' "$table" | awk -v g="$1" -v t="${2#/dev/}" '$3 == g && $6 == t { print $1 }'
      }
      pane_tpgid() {
        printf '%s\n' "$table" | awk -v p="$1" '$1 == p { print $4 }'
      }
    fi

    # tmux: map each client in a session's foreground to its active pane through the
    # server it talks to (the inherited environment names the first client, so it is
    # never used), then report that pane's foreground job and visible screen.
    xcount=0
    ycount=0
    tdir="${TMUX_TMPDIR:-/tmp}/tmux-$uid"
    while read -r apid pane cpid exe; do
      [ -n "$exe" ] && [ -x "$exe" ] || continue
      found=
      for sock in "$tdir"/*; do
        [ -S "$sock" ] || continue
        # Spaces, not TAB: under LC_ALL=C tmux prints control characters as `_`. None of
        # these fields can hold a space.
        found=$("$exe" -S "$sock" list-clients -F '#{client_pid} #{pane_id} #{pane_tty} #{pane_in_mode} #{pane_pid}' \
          2>/dev/null | awk -v p="$cpid" '$1 == p { print; exit }')
        [ -n "$found" ] && break
      done
      [ -n "$found" ] || continue
      # shellcheck disable=SC2086
      set -- $found
      tpane=$2
      ptty=$3
      mode=$4
      ppid=$5
      fg=$(pane_tpgid "$ppid")
      [ -n "$fg" ] || fg=-1
      printf 'X\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$apid" "$cpid" "$tpane" "$ptty" "${mode:-0}" "$fg"
      xcount=$((xcount + 1))
      job=$(pane_job "$fg" "$ptty")
      if [ -r /proc/self/stat ]; then
        for m in $job; do member Y "$pane" "$m"; done
      elif [ -n "$job" ]; then
        render Y "$(printf '%s\n' "$job" | awk -v a="$pane" -v g="$fg" -v t="${ptty#/dev/}" '{ print a, g, t, $1 }')"
      fi
      ycount=$((ycount + $(printf '%s\n' "$job" | awk 'NF { n++ } END { print n + 0 }')))
      # The x keeps a trailing newline; one byte past the cap marks the text truncated.
      screen=$("$exe" -S "$sock" capture-pane -p -t "$tpane" 2>/dev/null | head -c $((cap + 1)); printf x)
      screen=${screen%x}
      truncated=0
      if [ "$(printf '%s' "$screen" | wc -c)" -gt "$cap" ]; then
        truncated=1
        screen=$(printf '%s' "$screen" | head -c "$cap"; printf x)
        screen=${screen%x}
      fi
      printf '%s' "$screen" | PROWL_PANE="$pane" awk -v t="$truncated" '
        BEGIN { RS = "\001"; ORS = "" }
        { s = $0; gsub(/%/, "%25", s); gsub(/\t/, "%09", s); gsub(/\n/, "%0A", s); gsub(/\r/, "%0D", s)
          p = ENVIRON["PROWL_PANE"]; gsub(/%/, "%25", p); gsub(/\t/, "%09", p)
          printf "C\t%s\t%s\t%s\n", p, t, s; done = 1 }
        END { if (!done) printf "C\t%s\t%s\t\n", ENVIRON["PROWL_PANE"], t }'
    done <<EOF
    $clients
    EOF
    printf 'END\t%s\t%s\t%s\t%s\n' "$scount" "$pcount" "$xcount" "$ycount"

    """#
}
