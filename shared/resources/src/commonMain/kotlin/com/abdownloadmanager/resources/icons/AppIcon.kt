package com.abdownloadmanager.resources.icons

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

private fun buildAppIcon(
    name: String,
    background: Brush,
    folder: Brush,
    arrow: Brush,
    border: Color,
): ImageVector = ImageVector.Builder(
    name = name,
    defaultWidth = 48.dp,
    defaultHeight = 48.dp,
    viewportWidth = 48f,
    viewportHeight = 48f,
).apply {
    path(fill = background) {
        moveTo(14.906f, 1.5f)
        horizontalLineTo(33.094f)
        curveTo(40.5f, 1.5f, 46.5f, 7.5f, 46.5f, 14.906f)
        verticalLineTo(33.094f)
        curveTo(46.5f, 40.5f, 40.5f, 46.5f, 33.094f, 46.5f)
        horizontalLineTo(14.906f)
        curveTo(7.5f, 46.5f, 1.5f, 40.5f, 1.5f, 33.094f)
        verticalLineTo(14.906f)
        curveTo(1.5f, 7.5f, 7.5f, 1.5f, 14.906f, 1.5f)
        close()
    }
    path(
        fill = SolidColor(Color.Transparent),
        stroke = SolidColor(border),
        strokeLineWidth = 0.14f,
    ) {
        moveTo(14.906f, 1.57f)
        horizontalLineTo(33.094f)
        curveTo(40.461f, 1.57f, 46.43f, 7.539f, 46.43f, 14.906f)
        verticalLineTo(33.094f)
        curveTo(46.43f, 40.461f, 40.461f, 46.43f, 33.094f, 46.43f)
        horizontalLineTo(14.906f)
        curveTo(7.539f, 46.43f, 1.57f, 40.461f, 1.57f, 33.094f)
        verticalLineTo(14.906f)
        curveTo(1.57f, 7.539f, 7.539f, 1.57f, 14.906f, 1.57f)
        close()
    }
    path(fill = folder) {
        moveTo(7.125f, 19.406f)
        verticalLineTo(17.812f)
        curveTo(7.125f, 15.75f, 8.812f, 14.156f, 10.875f, 14.156f)
        horizontalLineTo(19.406f)
        curveTo(20.625f, 14.156f, 21.75f, 14.719f, 22.453f, 15.703f)
        lineTo(24.375f, 17.906f)
        horizontalLineTo(37.125f)
        curveTo(39.375f, 17.906f, 40.875f, 19.406f, 40.875f, 21.656f)
        verticalLineTo(32.812f)
        curveTo(40.875f, 35.437f, 39f, 37.312f, 36.375f, 37.312f)
        horizontalLineTo(11.625f)
        curveTo(9f, 37.312f, 7.125f, 35.437f, 7.125f, 32.812f)
        close()
    }
    path(fill = arrow) {
        moveTo(24f, 6.187f)
        curveTo(22.922f, 6.187f, 22.078f, 7.031f, 22.078f, 8.109f)
        verticalLineTo(20.156f)
        horizontalLineTo(18.516f)
        curveTo(17.391f, 20.156f, 16.406f, 20.812f, 16.031f, 21.844f)
        curveTo(15.656f, 22.875f, 15.938f, 23.953f, 16.734f, 24.75f)
        lineTo(22.594f, 30.609f)
        curveTo(23.391f, 31.406f, 24.609f, 31.406f, 25.406f, 30.609f)
        lineTo(31.266f, 24.75f)
        curveTo(32.062f, 23.953f, 32.344f, 22.875f, 31.969f, 21.844f)
        curveTo(31.594f, 20.812f, 30.609f, 20.156f, 29.484f, 20.156f)
        horizontalLineTo(25.922f)
        verticalLineTo(8.109f)
        curveTo(25.922f, 7.031f, 25.078f, 6.187f, 24f, 6.187f)
        close()
    }
}.build()

private var _AppIconLight: ImageVector? = null

val ABDMIcons.AppIconLight: ImageVector
    get() = _AppIconLight ?: buildAppIcon(
        name = "AppIconLight",
        background = Brush.linearGradient(
            colors = listOf(Color(0xFFF8FAFC), Color(0xFFE7EEF5)),
            start = Offset(5.16f, 3.84f),
            end = Offset(43.13f, 44.16f),
        ),
        folder = Brush.linearGradient(
            colors = listOf(Color(0xFF20B8A9), Color(0xFF397FD6)),
            start = Offset(7.88f, 15.66f),
            end = Offset(40.13f, 37.22f),
        ),
        arrow = Brush.linearGradient(
            colors = listOf(Color(0xFF172536), Color(0xFF234259)),
            start = Offset(21.28f, 6.94f),
            end = Offset(26.72f, 25.88f),
        ),
        border = Color(0x24172536),
    ).also { _AppIconLight = it }

private var _AppIconDark: ImageVector? = null

val ABDMIcons.AppIconDark: ImageVector
    get() = _AppIconDark ?: buildAppIcon(
        name = "AppIconDark",
        background = Brush.linearGradient(
            colors = listOf(Color(0xFF1A2A3B), Color(0xFF171A2A)),
            start = Offset(5.16f, 3.84f),
            end = Offset(43.13f, 44.16f),
        ),
        folder = Brush.linearGradient(
            colors = listOf(Color(0xFF55D9C8), Color(0xFF4C91F2)),
            start = Offset(7.88f, 15.66f),
            end = Offset(40.13f, 37.22f),
        ),
        arrow = Brush.linearGradient(
            colors = listOf(Color.White, Color(0xFFDDFBF6)),
            start = Offset(21.28f, 6.94f),
            end = Offset(26.72f, 25.88f),
        ),
        border = Color(0x1AFFFFFF),
    ).also { _AppIconDark = it }

// Keep the original resource name available to callers outside this module.
val ABDMIcons.AppIcon: ImageVector
    get() = AppIconLight
