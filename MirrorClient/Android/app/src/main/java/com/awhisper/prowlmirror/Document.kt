package com.awhisper.prowlmirror

sealed interface Block {
    val raw: String

    data class Text(override val raw: String) : Block

    data class Code(val language: String, override val raw: String) : Block

    data class Table(val rows: List<List<String>>, override val raw: String) : Block
}

object Document {
    fun chunks(text: String): List<String> {
        val chunks = mutableListOf<String>()
        var start = 0
        while (start < text.length) {
            var end = minOf(start + 4096, text.length)
            if (end < text.length && text[end - 1].isHighSurrogate()) end--
            chunks += text.substring(start, end)
            start = end
        }
        return chunks
    }

    fun blocks(text: String): List<Block> {
        val lines = text.split('\n')
        val output = mutableListOf<Block>()
        val pending = StringBuilder()
        fun flush() {
            if (pending.isNotEmpty()) {
                // Bound individual layout work without splitting a UTF-16 surrogate pair.
                output += chunks(pending.toString()).map(Block::Text)
                pending.clear()
            }
        }
        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            if (line.trimStart().startsWith("```")) {
                flush()
                val language = line.trim().drop(3)
                val code = mutableListOf<String>()
                index++
                while (index < lines.size && !lines[index].trimStart().startsWith("```")) code +=
                    lines[index++]
                output += Block.Code(language, code.joinToString("\n"))
                if (index < lines.size) index++
                continue
            }
            val header = cells(line)
            val separator = lines.getOrNull(index + 1)?.let(::cells)
            if (
                header != null &&
                    separator != null &&
                    header.size == separator.size &&
                    separator.all { it.matches(Regex(":?-{3,}:?")) }
            ) {
                flush()
                val rows = mutableListOf(header)
                val raw = mutableListOf(line, lines[index + 1])
                index += 2
                while (index < lines.size) {
                    val row = cells(lines[index]) ?: break
                    if (row.size != header.size) break
                    rows += row
                    raw += lines[index++]
                }
                output += Block.Table(rows, raw.joinToString("\n"))
                continue
            }
            pending.append(line)
            if (index < lines.lastIndex) pending.append('\n')
            index++
            if (pending.length >= 4096) flush()
        }
        flush()
        return output
    }

    private fun cells(line: String): List<String>? {
        val s = line.trim()
        if (!s.startsWith('|') || !s.endsWith('|') || s.contains("\\|")) return null
        return s.drop(1).dropLast(1).split('|').map(String::trim).takeIf { it.size > 1 }
    }
}

/** Only hardware Return can arm the gesture. Arbitrary text/selection edits cancel it. */
class DoubleReturn {
    private data class Candidate(val text: String, val cursor: Int, val time: Long)

    private var candidate: Candidate? = null

    fun cancel() {
        candidate = null
    }

    fun validate(text: String, cursor: Int) {
        if (candidate?.text != text || candidate?.cursor != cursor) cancel()
    }

    fun record(text: String, cursor: Int, time: Long) {
        candidate = Candidate(text, cursor, time)
    }

    fun consume(text: String, cursor: Int, time: Long): String? {
        val old = candidate
        candidate = null
        return if (
            old != null &&
                old.text == text &&
                old.cursor == cursor &&
                time - old.time in 0..350 &&
                cursor > 0 &&
                text[cursor - 1] == '\n'
        )
            text.removeRange(cursor - 1, cursor)
        else null
    }
}
