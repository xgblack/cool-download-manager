package com.abdownloadmanager.desktop.pages.singleDownloadPage

import com.abdownloadmanager.desktop.DesktopDownloadDialogManager
import com.abdownloadmanager.desktop.window.custom.CustomWindow
import com.abdownloadmanager.desktop.window.custom.WindowIcon
import com.abdownloadmanager.desktop.window.custom.WindowTitle
import com.abdownloadmanager.shared.util.ui.icon.MyIcons
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.FrameWindowScope
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.rememberWindowState
import com.abdownloadmanager.shared.util.ui.theme.LocalUiScale
import ir.amirab.downloader.downloaditem.DownloadJobStatus
import ir.amirab.downloader.monitor.CompletedDownloadItemState
import ir.amirab.downloader.monitor.IDownloadItemState
import ir.amirab.downloader.monitor.ProcessingDownloadItemState
import ir.amirab.downloader.monitor.statusOrFinished
import ir.amirab.downloader.utils.ExceptionUtils
import ir.amirab.util.desktop.screen.applyUiScale
import ir.amirab.util.desktop.PlatformAppActivator
import java.awt.Dimension
import java.awt.EventQueue
import java.awt.Taskbar
import java.awt.Window
import java.awt.event.WindowAdapter
import java.awt.event.WindowEvent

@Composable
private fun getDownloadTitle(itemState: IDownloadItemState): String {
    return buildString {
        if (itemState is ProcessingDownloadItemState && itemState.percent != null) {
            append("${itemState.percent}%")
            append(" ")
        }
        append(itemState.name)
    }
}

val LocalSingleDownloadPageSizing =
    compositionLocalOf<SingleProgressDownloadPageSizing> { error("LocalSingleBoxSizing not provided") }

@Stable
class SingleProgressDownloadPageSizing {
    var resizingPartInfo by mutableStateOf(false)
    var partInfoHeight by mutableStateOf(150.dp)
}

@Composable
fun ShowDownloadDialogs(component: DesktopDownloadDialogManager) {
    val openedDownloadDialogs = component.openedDownloadDialogs.collectAsState().value
    for (singleDownloadComponent in openedDownloadDialogs) {
        key(singleDownloadComponent.downloadId) {
            ShowDownloadDialog(singleDownloadComponent)
        }
    }
}

@Composable
private fun ShowDownloadDialog(singleDownloadComponent: DesktopSingleDownloadComponent) {
    val itemState by singleDownloadComponent.itemStateFlow.collectAsState()
    itemState?.let { DownloadWindow(singleDownloadComponent, it) }
}

@Composable
private fun DownloadWindow(
    singleDownloadComponent: DesktopSingleDownloadComponent,
    itemState: IDownloadItemState,
) {
    val uiScale = LocalUiScale.current
    val showPartInfo by singleDownloadComponent.showPartInfo.collectAsState()
    val singleDownloadPageSizing = remember(showPartInfo) { SingleProgressDownloadPageSizing() }
    val baseSize = when (itemState) {
        is CompletedDownloadItemState -> DpSize(width = 450.dp, height = 160.dp)
        is ProcessingDownloadItemState -> DpSize(width = 450.dp, height = 290.dp)
    }.applyUiScale(uiScale)
    val targetSize = when (itemState) {
        is CompletedDownloadItemState -> baseSize
        is ProcessingDownloadItemState -> {
            val partInfoHeight = if (showPartInfo) {
                singleDownloadPageSizing.partInfoHeight.value.applyUiScale(uiScale).dp
            } else {
                0.dp
            }
            baseSize.copy(height = baseSize.height + partInfoHeight)
        }
    }
    val state = rememberWindowState(
        size = targetSize,
        position = WindowPosition(Alignment.Center)
    )
    val windowFocusRequestCount by singleDownloadComponent.windowFocusRequestCount.collectAsState()
    var focusable by remember { mutableStateOf(windowFocusRequestCount > 0) }
    CustomWindow(
        state = state,
        onRequestToggleMaximize = null,
        resizable = false,
        focusable = focusable,
        onCloseRequest = singleDownloadComponent::close,
    ) {
        HandleWindowFocusRequests(
            requestCount = windowFocusRequestCount,
            onRestoreFocusable = { focusable = true },
            onRequestFocus = {
                state.isMinimized = false
                requestWindowFocus(window)
            },
        )
        WindowTitle(getDownloadTitle(itemState))
        WindowIcon(MyIcons.appIcon)
        UpdateTaskBar(window, itemState)
        LaunchedEffect(baseSize, targetSize) {
            window.minimumSize = Dimension(
                baseSize.width.value.toInt(),
                baseSize.height.value.toInt(),
            )
            state.size = targetSize
        }
        when (itemState) {
            is CompletedDownloadItemState -> CompletedDownloadPage(
                singleDownloadComponent,
                itemState,
            )

            is ProcessingDownloadItemState -> CompositionLocalProvider(
                LocalSingleDownloadPageSizing provides singleDownloadPageSizing
            ) {
                ProgressDownloadPage(
                    singleDownloadComponent,
                    itemState,
                )
            }
        }
    }
}

@Composable
private fun FrameWindowScope.HandleWindowFocusRequests(
    requestCount: Long,
    onRestoreFocusable: () -> Unit,
    onRequestFocus: () -> Unit,
) {
    var windowShown by remember { mutableStateOf(false) }
    var handledRequestCount by remember { mutableLongStateOf(0L) }
    DisposableEffect(window) {
        fun handleWindowShown() {
            EventQueue.invokeLater {
                if (!window.isShowing) return@invokeLater
                window.focusableWindowState = true
                onRestoreFocusable()
                windowShown = true
            }
        }

        val listener = object : WindowAdapter() {
            override fun windowOpened(event: WindowEvent) {
                handleWindowShown()
            }
        }
        window.addWindowListener(listener)
        if (window.isShowing) {
            handleWindowShown()
        }
        onDispose {
            window.removeWindowListener(listener)
        }
    }

    LaunchedEffect(requestCount, windowShown) {
        if (!windowShown || requestCount <= handledRequestCount) return@LaunchedEffect
        EventQueue.invokeLater {
            if (!window.isShowing || requestCount <= handledRequestCount) return@invokeLater
            onRequestFocus()
            handledRequestCount = requestCount
        }
    }
}

private fun requestWindowFocus(window: Window) {
    window.focusableWindowState = true
    PlatformAppActivator.active()
    window.toFront()
    window.requestFocus()
}

@Composable
private fun UpdateTaskBar(
    window: Window,
    state: IDownloadItemState,
) {
    val percent = state.getPercent()
    val status = state.statusOrFinished()
    LaunchedEffect(percent, status, window) {
        if (!Taskbar.isTaskbarSupported()) return@LaunchedEffect
        runCatching {
            val taskbar = Taskbar.getTaskbar()
            percent?.let {
                taskbar.setWindowProgressValue(
                    window,
                    percent
                )
            }
            taskbar.setWindowProgressState(
                window,
                when (status) {
                    is DownloadJobStatus.Canceled -> {
                        if (ExceptionUtils.isNormalCancellation(status.e)) {
                            Taskbar.State.PAUSED
                        } else {
                            Taskbar.State.ERROR
                        }
                    }

                    DownloadJobStatus.Downloading,
                    is DownloadJobStatus.Retrying -> {
                        if (percent != null) {
                            Taskbar.State.NORMAL
                        } else {
                            Taskbar.State.INDETERMINATE
                        }
                    }

                    DownloadJobStatus.Resuming -> {
                        Taskbar.State.INDETERMINATE
                    }

                    DownloadJobStatus.Finished -> {
                        Taskbar.State.OFF
                    }

                    DownloadJobStatus.IDLE -> {
                        Taskbar.State.OFF
                    }

                    is DownloadJobStatus.PreparingFile -> {
                        Taskbar.State.INDETERMINATE
                    }
                }
            )
        }
    }
}


private fun IDownloadItemState.getPercent(): Int? {
    return when (this) {
        is CompletedDownloadItemState -> 100
        is ProcessingDownloadItemState -> percent
    }
}

private fun IDownloadItemState.isActive(): Boolean {
    return when (this) {
        is CompletedDownloadItemState -> false
        is ProcessingDownloadItemState -> status is DownloadJobStatus.IsActive
    }
}
