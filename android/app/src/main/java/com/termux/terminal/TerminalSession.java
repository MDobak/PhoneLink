package com.termux.terminal;

import java.util.Arrays;
import java.util.UUID;

/**
 * A terminal session that has no local process. Phone Link changed this file: the original Termux class starts a
 * process on a local pty through JNI. This class sends the keyboard input to a {@link Transport} (the shell on the
 * Mac), and it receives the output of the shell through {@link #appendOutput(byte[], int)}.
 * <p>
 * Call all methods on the main thread.
 */
public final class TerminalSession extends TerminalOutput {

    /** The connection to the remote shell. */
    public interface Transport {
        /** Sends keyboard input to the remote shell. */
        void write(byte[] data, int offset, int count);

        /** The size of the terminal changed (or the emulator starts). */
        void resize(int columns, int rows, int cellWidthPixels, int cellHeightPixels);
    }

    public final String mHandle = UUID.randomUUID().toString();

    TerminalEmulator mEmulator;

    /** Callback which gets notified when a session finishes or changes title. */
    TerminalSessionClient mClient;

    private final Transport mTransport;
    private final Integer mTranscriptRows;

    /** Output that arrived before the emulator started (the size was not known). */
    private byte[] mBacklog = new byte[0];
    private static final int MAX_BACKLOG = 1024 * 1024;

    private int mCellWidth = 1, mCellHeight = 1;
    private boolean mRunning = true;
    private int mExitStatus;

    /** Set by the application for user identification of session, not by terminal. */
    public String mSessionName;

    private final byte[] mUtf8InputBuffer = new byte[5];

    public TerminalSession(Transport transport, Integer transcriptRows, TerminalSessionClient client) {
        mTransport = transport;
        mTranscriptRows = transcriptRows;
        mClient = client;
    }

    public void updateTerminalSessionClient(TerminalSessionClient client) {
        mClient = client;
        if (mEmulator != null) mEmulator.updateTerminalSessionClient(client);
    }

    /** Tells the remote shell the new size, and starts or resizes the emulator. */
    public void updateSize(int columns, int rows, int cellWidthPixels, int cellHeightPixels) {
        mCellWidth = cellWidthPixels;
        mCellHeight = cellHeightPixels;
        if (mEmulator == null) {
            mEmulator = new TerminalEmulator(this, columns, rows, cellWidthPixels, cellHeightPixels, mTranscriptRows, mClient);
            if (mBacklog.length > 0) {
                byte[] b = mBacklog;
                mBacklog = new byte[0];
                mEmulator.append(b, b.length);
            }
        } else {
            mEmulator.resize(columns, rows, cellWidthPixels, cellHeightPixels);
        }
        mTransport.resize(columns, rows, cellWidthPixels, cellHeightPixels);
    }

    /** True when the emulator started. */
    public boolean isInitialized() {
        return mEmulator != null;
    }

    /** Makes a new, empty emulator with the same size (for example, before the Mac sends the recent output again). */
    public void recreateEmulator() {
        mBacklog = new byte[0];
        if (mEmulator == null) return;
        mEmulator = new TerminalEmulator(this, mEmulator.mColumns, mEmulator.mRows, mCellWidth, mCellHeight, mTranscriptRows, mClient);
        notifyScreenUpdate();
    }

    /** Output from the remote shell. */
    public void appendOutput(byte[] data, int length) {
        if (mEmulator == null) {
            int keep = Math.min(MAX_BACKLOG, mBacklog.length + length);
            byte[] n = new byte[keep];
            int fromOld = keep - length;
            if (fromOld > 0) System.arraycopy(mBacklog, mBacklog.length - fromOld, n, 0, fromOld);
            System.arraycopy(data, Math.max(0, length - keep), n, Math.max(0, fromOld), Math.min(length, keep));
            mBacklog = n;
            return;
        }
        mEmulator.append(data, length);
        notifyScreenUpdate();
    }

    /** The terminal title as set through escape sequences or null if none set. */
    public String getTitle() {
        return (mEmulator == null) ? null : mEmulator.getTitle();
    }

    /** Write data to the remote shell. */
    @Override
    public void write(byte[] data, int offset, int count) {
        if (mRunning) mTransport.write(data, offset, count);
    }

    /** Write the Unicode code point to the terminal encoded in UTF-8. */
    public void writeCodePoint(boolean prependEscape, int codePoint) {
        if (codePoint > 1114111 || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
            throw new IllegalArgumentException("Invalid code point: " + codePoint);
        }
        int p = 0;
        if (prependEscape) mUtf8InputBuffer[p++] = 27;
        if (codePoint <= 0x7f) {
            mUtf8InputBuffer[p++] = (byte) codePoint;
        } else if (codePoint <= 0x7ff) {
            mUtf8InputBuffer[p++] = (byte) (0xc0 | (codePoint >> 6));
            mUtf8InputBuffer[p++] = (byte) (0x80 | (codePoint & 0x3f));
        } else if (codePoint <= 0xffff) {
            mUtf8InputBuffer[p++] = (byte) (0xe0 | (codePoint >> 12));
            mUtf8InputBuffer[p++] = (byte) (0x80 | ((codePoint >> 6) & 0x3f));
            mUtf8InputBuffer[p++] = (byte) (0x80 | (codePoint & 0x3f));
        } else {
            mUtf8InputBuffer[p++] = (byte) (0xf0 | (codePoint >> 18));
            mUtf8InputBuffer[p++] = (byte) (0x80 | ((codePoint >> 12) & 0x3f));
            mUtf8InputBuffer[p++] = (byte) (0x80 | ((codePoint >> 6) & 0x3f));
            mUtf8InputBuffer[p++] = (byte) (0x80 | (codePoint & 0x3f));
        }
        write(Arrays.copyOf(mUtf8InputBuffer, p), 0, p);
    }

    public TerminalEmulator getEmulator() {
        return mEmulator;
    }

    /** Notify the {@link #mClient} that the screen has changed. */
    protected void notifyScreenUpdate() {
        if (mClient != null) mClient.onTextChanged(this);
    }

    /** Reset state for terminal emulator state. */
    public void reset() {
        if (mEmulator == null) return;
        mEmulator.reset();
        notifyScreenUpdate();
    }

    /** The remote shell stopped. */
    public synchronized void setExited(int exitStatus) {
        mRunning = false;
        mExitStatus = exitStatus;
    }

    /** A new remote shell started for this session. */
    public synchronized void setRunning() {
        mRunning = true;
    }

    /** Phone Link has no local process to stop. */
    public void finishIfRunning() {
    }

    @Override
    public void titleChanged(String oldTitle, String newTitle) {
        if (mClient != null) mClient.onTitleChanged(this);
    }

    public synchronized boolean isRunning() {
        return mRunning;
    }

    /** Only valid if not {@link #isRunning()}. */
    public synchronized int getExitStatus() {
        return mExitStatus;
    }

    @Override
    public void onCopyTextToClipboard(String text) {
        if (mClient != null) mClient.onCopyTextToClipboard(this, text);
    }

    @Override
    public void onPasteTextFromClipboard() {
        if (mClient != null) mClient.onPasteTextFromClipboard(this);
    }

    @Override
    public void onBell() {
        if (mClient != null) mClient.onBell(this);
    }

    @Override
    public void onColorsChanged() {
        if (mClient != null) mClient.onColorsChanged(this);
    }

    public int getPid() {
        return -1;
    }

    public String getCwd() {
        return null;
    }
}
