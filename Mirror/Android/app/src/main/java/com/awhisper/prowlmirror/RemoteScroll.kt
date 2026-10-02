package com.awhisper.prowlmirror

enum class ScrollDirection(val wireName: String) {
    UP("up"),
    DOWN("down"),
}

data class ScrollCompletion(val requestID: String, val direction: ScrollDirection)

data class ScrollBounds(val atTop: Boolean? = null, val atBottom: Boolean? = null) {
    fun allows(direction: ScrollDirection): Boolean =
        (if (direction == ScrollDirection.UP) atTop else atBottom) != true
}
