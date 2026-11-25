package com.onevcat.prowl.mirror

sealed interface Block {
    val raw: String

    data class Text(override val raw: String, val whole: String? = null) : Block

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

    fun blocks(text: String, splitText: Boolean = true): List<Block> {
        val lines = text.split('\n')
        val output = mutableListOf<Block>()
        val pending = StringBuilder()
        fun flush() {
            if (pending.isNotEmpty()) {
                // Bound individual layout work without splitting a UTF-16 surrogate pair.
                val whole = pending.toString()
                val pieces = if (splitText) chunks(whole) else listOf(whole)
                output += pieces.map { Block.Text(it, whole.takeIf { pieces.size > 1 }) }
                pending.clear()
            }
        }
        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            val fence = fenceOpening(line)
            if (fence != null) {
                flush()
                val code = mutableListOf<String>()
                index++
                while (index < lines.size) {
                    val candidate = lines[index++]
                    if (fence.closes(candidate)) break
                    val indent = candidate.takeWhile { it == ' ' }.length.coerceAtMost(fence.indent)
                    code += candidate.drop(indent)
                }
                output += Block.Code(fence.language, code.joinToString("\n"))
                continue
            }
            val header = cells(line)
            val separator = lines.getOrNull(index + 1)?.let(::cells)
            if (line.contains('|') && separator != null && header.size == separator.size &&
                separator.all { it.contains('-') && it.all { c -> c == '-' || c == ':' } }
            ) {
                flush()
                val rows = mutableListOf(header)
                val raw = mutableListOf(line, lines[index + 1])
                index += 2
                while (index < lines.size && lines[index].contains('|') && lines[index].isNotBlank()) {
                    val row = cells(lines[index])
                    rows += List(header.size) { row.getOrElse(it) { "" } }
                    raw += lines[index++]
                }
                output += Block.Table(rows, raw.joinToString("\n"))
                continue
            }
            pending.append(line)
            if (index < lines.lastIndex) pending.append('\n')
            index++
        }
        flush()
        return output
    }

    private data class Fence(val marker: Char, val length: Int, val indent: Int, val language: String) {
        fun closes(line: String): Boolean {
            val closing = line.trim()
            return closing.length >= length && closing.all { it == marker }
        }
    }

    private fun fenceOpening(line: String): Fence? {
        val indent = line.takeWhile { it == ' ' }.length
        val opening = line.drop(indent)
        val marker = opening.firstOrNull()?.takeIf { it == '`' || it == '~' } ?: return null
        val length = opening.takeWhile { it == marker }.length
        if (length < 3) return null
        val info = opening.drop(length).trim()
        if (marker == '`' && '`' in info) return null
        return Fence(marker, length, indent, info)
    }

    private fun cells(line: String): List<String> {
        val trimmed = line.trim().removePrefix("|").let {
            if (it.endsWith("|") && !it.endsWith("\\|")) it.dropLast(1) else it
        }
        val cells = mutableListOf<String>()
        val cell = StringBuilder()
        var escaped = false
        for (character in trimmed) {
            when {
                escaped -> {
                    if (character != '|') cell.append('\\')
                    cell.append(character)
                    escaped = false
                }
                character == '\\' -> escaped = true
                character == '|' -> {
                    cells += cell.toString().trim()
                    cell.clear()
                }
                else -> cell.append(character)
            }
        }
        if (escaped) cell.append('\\')
        cells += cell.toString().trim()
        return cells
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
