// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ecstasy (https://github.com/xfhrv)
//
// Three-finger drag engine for Windows Precision Touchpads.
//
// Reads raw HID input reports from the touchpad (usage page 0x0D usage 0x05),
// tracks contact positions, and synthesizes a left-button drag while three
// fingers are held down and moved. The regular one-finger mouse movement is
// not affected.
//
// The HID report parsing is adapted from emoacht/RawInput.Touchpad (MIT license,
// Copyright (c) 2021 emoacht), rewritten for caching and our drag engine.
// Drag state machine inspired by ClementGre/ThreeFingerDragOnWindows (MIT license,
// Copyright (c) 2022 Clement Grennerat).

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TouchpadTuner.Helper
{
    public static class ThreeFingerDragEngine
    {
        // ------------------------------------------------------------------
        // Tuning constants
        // ------------------------------------------------------------------
        private const double StartDistanceUnits = 18.0;   // finger travel needed to start a drag (touchpad units)
        private const int StartStableFrames = 2;          // must have exactly 3 matching contacts for this many frames
        private const int EndGraceMs = 80;                // release the button after this long without 3 contacts
        private const int WatchdogTimeoutMs = 700;        // release if reports stop arriving entirely
        private const double MinSensitivity = 0.2;
        private const double MaxSensitivity = 3.0;

        // ------------------------------------------------------------------
        // Public state (read by the UI)
        // ------------------------------------------------------------------
        private static volatile bool _running;
        private static volatile bool _enabled;
        private static volatile int _sensitivityPercent = 100;
        private static volatile int _contactCount;
        private static volatile bool _dragging;
        private static long _frames;
        private static volatile string _status = "未启动";
        private static volatile string _error = "";
        private static volatile bool _touchpadFound;

        public static bool IsRunning { get { return _running; } }
        public static bool TouchpadFound { get { return _touchpadFound; } }
        public static int ContactCount { get { return _contactCount; } }
        public static bool IsDragging { get { return _dragging; } }
        public static long Frames { get { return Interlocked.Read(ref _frames); } }
        public static string Status { get { return _status; } }
        public static string Error { get { return _error; } }

        public static bool Enabled
        {
            get { return _enabled; }
            set
            {
                _enabled = value;
                if (!value) EndDrag("disabled");
            }
        }

        public static double Sensitivity
        {
            get { return _sensitivityPercent / 100.0; }
            set
            {
                double v = value;
                if (v < MinSensitivity) v = MinSensitivity;
                if (v > MaxSensitivity) v = MaxSensitivity;
                _sensitivityPercent = (int)Math.Round(v * 100.0);
            }
        }

        // ------------------------------------------------------------------
        // Thread / hidden window
        // ------------------------------------------------------------------
        private static Thread _thread;
        private static uint _threadId;
        private static volatile bool _stopRequested;
        private static IntPtr _hwnd;
        private static WndProcDelegate _wndProc;
        private static readonly ManualResetEvent _initDone = new ManualResetEvent(false);
        private static Timer _watchdog;

        private const int WM_INPUT = 0x00FF;
        private const int WM_INPUT_DEVICE_CHANGE = 0x00FE;
        private const int WM_QUIT = 0x0012;
        private const int WM_CLOSE = 0x0010;
        private const uint RIM_TYPEHID = 2;
        private const uint RIDEV_INPUTSINK = 0x00000100;
        private const uint RIDEV_DEVNOTIFY = 0x00002000;

        public static bool Start()
        {
            if (_running) return true;
            _stopRequested = false;
            _error = "";
            _initDone.Reset();
            _thread = new Thread(ThreadMain);
            _thread.IsBackground = true;
            _thread.Name = "TouchpadTuner.Helper";
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
            _initDone.WaitOne(3000);
            if (_running && _watchdog == null)
            {
                _watchdog = new Timer(WatchdogTick, null, 200, 200);
            }
            return _running;
        }

        public static void Stop()
        {
            if (!_running) return;
            _stopRequested = true;
            if (_threadId != 0)
            {
                uint tid = _threadId;
                try { PostThreadMessage(tid, WM_QUIT, IntPtr.Zero, IntPtr.Zero); }
                catch (Exception) { }
            }
            try { if (_thread != null) _thread.Join(1500); }
            catch (Exception) { }
            _running = false;
            _enabled = false;
            EndDrag("stopped");
            _status = "未启动";
        }

        private static void WatchdogTick(object state)
        {
            if (_dragging)
            {
                int last = _lastFrameTicks;
                if (last != 0 && Environment.TickCount - last > WatchdogTimeoutMs)
                {
                    EndDrag("watchdog");
                }
            }
        }

        private static void ThreadMain()
        {
            _threadId = GetCurrentThreadId();
            try
            {
                _wndProc = WindowProc;
                WNDCLASSEX wc = new WNDCLASSEX();
                wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
                wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
                wc.hInstance = GetModuleHandleW(null);
                wc.lpszClassName = "TouchpadTunerDragWindow";
                ushort atom = RegisterClassExW(ref wc);
                if (atom == 0)
                {
                    _error = "RegisterClassEx 失败 (" + Marshal.GetLastWin32Error() + ")";
                    _status = "引擎启动失败";
                    return;
                }
                _hwnd = CreateWindowExW(0, "TouchpadTunerDragWindow", "touchpad tuner", 0,
                    0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (_hwnd == IntPtr.Zero)
                {
                    _error = "CreateWindowEx 失败 (" + Marshal.GetLastWin32Error() + ")";
                    _status = "引擎启动失败";
                    return;
                }

                RAWINPUTDEVICE rid = new RAWINPUTDEVICE();
                rid.usUsagePage = 0x000D; // HID_USAGE_PAGE_DIGITIZER
                rid.usUsage = 0x0005;     // HID_USAGE_DIGITIZER_TOUCHPAD
                rid.dwFlags = RIDEV_INPUTSINK | RIDEV_DEVNOTIFY;
                rid.hwndTarget = _hwnd;
                bool ok = RegisterRawInputDevices(new RAWINPUTDEVICE[] { rid }, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
                if (!ok)
                {
                    _error = "注册触摸板原始输入失败 (" + Marshal.GetLastWin32Error() + ")";
                    _status = "引擎启动失败";
                    return;
                }

                EnumerateTouchpads();
                _running = true;
                _status = _touchpadFound ? "监听中（已找到触摸板）" : "监听中（等待触摸板）";
                _initDone.Set();

                MSG msg;
                while (!_stopRequested && GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0)
                {
                    TranslateMessage(ref msg);
                    DispatchMessageW(ref msg);
                }
            }
            catch (Exception ex)
            {
                _error = ex.Message;
                _status = "引擎异常";
            }
            finally
            {
                _running = false;
                _initDone.Set();
                EndDrag("thread exit");
            }
        }

        private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
        private static WndProcDelegate _keepAlive;

        private static IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            _keepAlive = _wndProc;
            switch (msg)
            {
                case WM_INPUT:
                    try { HandleRawInput(lParam); }
                    catch (Exception ex) { _error = ex.Message; }
                    return IntPtr.Zero;
                case WM_INPUT_DEVICE_CHANGE:
                    return IntPtr.Zero;
                case WM_CLOSE:
                    DestroyWindow(hwnd);
                    return IntPtr.Zero;
                default:
                    return DefWindowProcW(hwnd, msg, wParam, lParam);
            }
        }

        // ------------------------------------------------------------------
        // Raw input parsing
        // ------------------------------------------------------------------
        private static readonly Dictionary<IntPtr, DeviceCache> _devices = new Dictionary<IntPtr, DeviceCache>();

        private class DeviceCache
        {
            public IntPtr Handle;
            public IntPtr PreparsedData;
            public HIDP_CAPS Caps;
            public HIDP_VALUE_CAPS[] ValueCaps;
            public bool HasContactCount;
            public int LogicalMaxX;
            public int LogicalMaxY;
            public int FailedLoad;
        }

        private class ContactCreator
        {
            public int? Id;
            public int? X;
            public int? Y;

            public bool TryCreate(out TouchpadContact contact)
            {
                if (Id.HasValue && X.HasValue && Y.HasValue)
                {
                    contact = new TouchpadContact(Id.Value, X.Value, Y.Value);
                    return true;
                }
                contact = new TouchpadContact(0, 0, 0);
                return false;
            }

            public void Clear()
            {
                Id = null;
                X = null;
                Y = null;
            }
        }

        private struct TouchpadContact
        {
            public int Id;
            public int X;
            public int Y;

            public TouchpadContact(int id, int x, int y)
            {
                Id = id;
                X = x;
                Y = y;
            }
        }

        private static void EnumerateTouchpads()
        {
            uint count = 0;
            uint itemSize = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICELIST));
            GetRawInputDeviceList(IntPtr.Zero, ref count, itemSize);
            if (count == 0) return;
            IntPtr list = Marshal.AllocHGlobal((int)(count * itemSize));
            try
            {
                if (GetRawInputDeviceList(list, ref count, itemSize) != count) return;
                for (int i = 0; i < count; i++)
                {
                    IntPtr p = new IntPtr(list.ToInt64() + i * itemSize);
                    RAWINPUTDEVICELIST item = (RAWINPUTDEVICELIST)Marshal.PtrToStructure(p, typeof(RAWINPUTDEVICELIST));
                    if (item.dwType != RIM_TYPEHID) continue;
                    DeviceCache cache = GetDevice(item.hDevice);
                    if (cache.HasContactCount)
                    {
                        _touchpadFound = true;
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(list);
            }
        }

        private static DeviceCache GetDevice(IntPtr handle)
        {
            DeviceCache cache;
            if (_devices.TryGetValue(handle, out cache)) return cache;

            cache = new DeviceCache();
            cache.Handle = handle;
            _devices[handle] = cache;

            uint size = 0;
            uint r = GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, IntPtr.Zero, ref size);
            if (r != 0 || size == 0)
            {
                cache.FailedLoad = 1;
                return cache;
            }
            IntPtr pd = Marshal.AllocHGlobal((int)size);
            cache.PreparsedData = pd;
            try
            {
                if (GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, pd, ref size) == unchecked((uint)-1))
                {
                    cache.FailedLoad = 2;
                    return cache;
                }
                HIDP_CAPS caps;
                if (HidP_GetCaps(pd, out caps) != HIDP_STATUS_SUCCESS)
                {
                    cache.FailedLoad = 3;
                    return cache;
                }
                cache.Caps = caps;
                if (caps.NumberInputValueCaps > 0)
                {
                    ushort n = caps.NumberInputValueCaps;
                    HIDP_VALUE_CAPS[] vcs = new HIDP_VALUE_CAPS[n];
                    if (HidP_GetValueCaps(0 /* HidP_Input */, vcs, ref n, pd) == HIDP_STATUS_SUCCESS)
                    {
                        cache.ValueCaps = vcs;
                    }
                }
                if (cache.ValueCaps != null)
                {
                    for (int i = 0; i < cache.ValueCaps.Length; i++)
                    {
                        HIDP_VALUE_CAPS v = cache.ValueCaps[i];
                        if (v.UsagePage == 0x000D && v.Usage == 0x0054 && v.LinkCollection == 0)
                        {
                            cache.HasContactCount = true;
                        }
                        if (v.UsagePage == 0x0001 && v.Usage == 0x0030 && v.LogicalMax > cache.LogicalMaxX)
                        {
                            cache.LogicalMaxX = v.LogicalMax;
                        }
                        if (v.UsagePage == 0x0001 && v.Usage == 0x0031 && v.LogicalMax > cache.LogicalMaxY)
                        {
                            cache.LogicalMaxY = v.LogicalMax;
                        }
                    }
                }
            }
            finally
            {
                if (cache.FailedLoad != 0 && cache.PreparsedData != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(cache.PreparsedData);
                    cache.PreparsedData = IntPtr.Zero;
                }
            }
            if (cache.HasContactCount)
            {
                _touchpadFound = true;
            }
            return cache;
        }

        private static void HandleRawInput(IntPtr hRawInput)
        {
            uint rawInputSize = 0;
            uint headerSize = (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER));
            if (GetRawInputData(hRawInput, RID_INPUT, IntPtr.Zero, ref rawInputSize, headerSize) != 0) return;

            IntPtr buffer = Marshal.AllocHGlobal((int)rawInputSize);
            try
            {
                if (GetRawInputData(hRawInput, RID_INPUT, buffer, ref rawInputSize, headerSize) != rawInputSize) return;

                RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(buffer, typeof(RAWINPUTHEADER));
                if (header.dwType != RIM_TYPEHID) return;

                RAWHID hid = (RAWHID)Marshal.PtrToStructure(
                    new IntPtr(buffer.ToInt64() + Marshal.SizeOf(typeof(RAWINPUTHEADER))), typeof(RAWHID));

                int reportLength = (int)hid.dwSizeHid;
                int reportCount = (int)hid.dwCount;
                if (reportLength <= 0 || reportCount <= 0) return;

                byte[] rawData = new byte[rawInputSize];
                Marshal.Copy(buffer, rawData, 0, (int)rawInputSize);
                int dataOffset = (int)rawInputSize - reportLength * reportCount;
                if (dataOffset < 0) return;

                DeviceCache device = GetDevice(header.hDevice);
                if (device.FailedLoad != 0 || !device.HasContactCount || device.ValueCaps == null) return;

                IntPtr dataPtr = Marshal.AllocHGlobal(reportLength * reportCount);
                try
                {
                    Marshal.Copy(rawData, dataOffset, dataPtr, reportLength * reportCount);
                    List<TouchpadContact> contacts = ParseContacts(device, dataPtr, reportLength, reportCount);
                    Interlocked.Increment(ref _frames);
                    OnContacts(contacts, device);
                }
                finally
                {
                    Marshal.FreeHGlobal(dataPtr);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static List<TouchpadContact> ParseContacts(DeviceCache device, IntPtr dataPtr, int reportLength, int reportCount)
        {
            List<TouchpadContact> contacts = new List<TouchpadContact>(5);
            List<ContactCreator> creators = new List<ContactCreator>(reportCount);
            int contactCount = -1;
            HIDP_VALUE_CAPS[] caps = device.ValueCaps;

            // Order caps by link collection (contacts are stored in separate link collections).
            int[] order = new int[caps.Length];
            for (int i = 0; i < order.Length; i++) order[i] = i;
            for (int i = 0; i < order.Length - 1; i++)
            {
                for (int j = i + 1; j < order.Length; j++)
                {
                    if (caps[order[j]].LinkCollection < caps[order[i]].LinkCollection)
                    {
                        int t = order[i];
                        order[i] = order[j];
                        order[j] = t;
                    }
                }
            }

            for (int oi = 0; oi < order.Length; oi++)
            {
                HIDP_VALUE_CAPS cap = caps[order[oi]];
                for (int reportIndex = 0; reportIndex < reportCount; reportIndex++)
                {
                    IntPtr reportPtr = new IntPtr(dataPtr.ToInt64() + reportLength * reportIndex);
                    uint value;
                    if (HidP_GetUsageValue(0 /* HidP_Input */, cap.UsagePage, cap.LinkCollection, cap.Usage,
                            out value, device.PreparsedData, reportPtr, (uint)reportLength) != HIDP_STATUS_SUCCESS)
                    {
                        continue;
                    }

                    if (cap.LinkCollection == 0)
                    {
                        if (cap.UsagePage == 0x000D && cap.Usage == 0x0054)
                        {
                            contactCount = (int)value;
                        }
                        continue;
                    }

                    while (creators.Count <= reportIndex)
                    {
                        creators.Add(new ContactCreator());
                    }

                    if (cap.UsagePage == 0x000D && cap.Usage == 0x0051)
                    {
                        creators[reportIndex].Id = (int)value;
                    }
                    else if (cap.UsagePage == 0x0001 && cap.Usage == 0x0030)
                    {
                        creators[reportIndex].X = (int)value;
                    }
                    else if (cap.UsagePage == 0x0001 && cap.Usage == 0x0031)
                    {
                        creators[reportIndex].Y = (int)value;
                    }
                    else
                    {
                        continue;
                    }

                    TouchpadContact created;
                    if ((contactCount == 0 || contactCount < 0 || contacts.Count < contactCount) &&
                        creators[reportIndex].TryCreate(out created))
                    {
                        contacts.Add(created);
                        creators[reportIndex].Clear();
                    }
                }

                if (contactCount > 0 && contacts.Count >= contactCount)
                {
                    break;
                }
            }

            return contacts;
        }

        // ------------------------------------------------------------------
        // Drag state machine
        // ------------------------------------------------------------------
        private static TouchpadContact[] _lastContacts = new TouchpadContact[0];
        private static int _lastFrameTicks;
        private static int _stableThreeFrames;
        private static double _startAccum;
        private static int _lastThreeTicks;
        private static double _fracX;
        private static double _fracY;
        private static int _cursorX;
        private static int _cursorY;
        private static int _vLeft;
        private static int _vTop;
        private static int _vWidth;
        private static int _vHeight;

        private static void OnContacts(List<TouchpadContact> contacts, DeviceCache device)
        {
            int now = Environment.TickCount;
            _lastFrameTicks = now;
            _contactCount = contacts.Count;

            if (!_enabled)
            {
                _stableThreeFrames = 0;
                _startAccum = 0;
                _lastContacts = contacts.ToArray();
                return;
            }

            double scaleX = ComputeScaleX(device);
            double scaleY = ComputeScaleY(device);
            double sensitivity = Sensitivity;

            if (_dragging)
            {
                if (contacts.Count == 3)
                {
                    _lastThreeTicks = now;
                    double sumDx = 0;
                    double sumDy = 0;
                    int matched = 0;
                    TouchpadContact[] prev = _lastContacts;
                    for (int i = 0; i < contacts.Count; i++)
                    {
                        TouchpadContact current = contacts[i];
                        TouchpadContact old;
                        if (FindContact(prev, current.Id, out old))
                        {
                            sumDx += current.X - old.X;
                            sumDy += current.Y - old.Y;
                            matched++;
                        }
                    }
                    if (matched == 3)
                    {
                        double dx = (sumDx / 3.0) * scaleX * sensitivity;
                        double dy = (sumDy / 3.0) * scaleY * sensitivity;
                        MoveCursor(dx, dy);
                    }
                }
                else if (now - _lastThreeTicks > EndGraceMs)
                {
                    EndDrag("fingers lifted");
                }
            }
            else if (contacts.Count == 3)
            {
                bool sameIds = SameContactIds(_lastContacts, contacts);
                if (sameIds && _stableThreeFrames >= 1)
                {
                    _stableThreeFrames++;
                    double maxDist = MaxDistance(_lastContacts, contacts);
                    _startAccum += maxDist;
                    if (_stableThreeFrames >= StartStableFrames && _startAccum >= StartDistanceUnits)
                    {
                        BeginDrag();
                    }
                }
                else
                {
                    _stableThreeFrames = 1;
                    _startAccum = 0;
                }
            }
            else
            {
                _stableThreeFrames = 0;
                _startAccum = 0;
            }

            _lastContacts = contacts.ToArray();
        }

        private static bool FindContact(TouchpadContact[] list, int id, out TouchpadContact found)
        {
            for (int i = 0; i < list.Length; i++)
            {
                if (list[i].Id == id)
                {
                    found = list[i];
                    return true;
                }
            }
            found = new TouchpadContact(0, 0, 0);
            return false;
        }

        private static bool SameContactIds(TouchpadContact[] a, List<TouchpadContact> b)
        {
            if (a.Length != b.Count || b.Count == 0) return false;
            for (int i = 0; i < b.Count; i++)
            {
                bool found = false;
                for (int j = 0; j < a.Length; j++)
                {
                    if (a[j].Id == b[i].Id) { found = true; break; }
                }
                if (!found) return false;
            }
            return true;
        }

        private static double MaxDistance(TouchpadContact[] a, List<TouchpadContact> b)
        {
            double max = 0;
            for (int i = 0; i < b.Count; i++)
            {
                TouchpadContact old;
                if (!FindContact(a, b[i].Id, out old)) continue;
                double dx = b[i].X - old.X;
                double dy = b[i].Y - old.Y;
                double dist = Math.Sqrt(dx * dx + dy * dy);
                if (dist > max) max = dist;
            }
            return max;
        }

        private static void BeginDrag()
        {
            _stableThreeFrames = 0;
            _startAccum = 0;
            SendMouseButton(true);
            _dragging = true;
            _fracX = 0;
            _fracY = 0;
            _lastThreeTicks = Environment.TickCount;
            _vLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
            _vTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
            _vWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            _vHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            if (_vWidth <= 0) _vWidth = GetSystemMetrics(SM_CXSCREEN);
            if (_vHeight <= 0) _vHeight = GetSystemMetrics(SM_CYSCREEN);
            POINT pt;
            if (GetCursorPos(out pt))
            {
                _cursorX = pt.X;
                _cursorY = pt.Y;
            }
            else
            {
                _cursorX = _vLeft + _vWidth / 2;
                _cursorY = _vTop + _vHeight / 2;
            }
            _status = "拖曳中";
        }

        private static void EndDrag(string reason)
        {
            if (!_dragging)
            {
                if (_status == "拖曳中") _status = "监听中";
                return;
            }
            _dragging = false;
            SendMouseButton(false);
            _stableThreeFrames = 0;
            _startAccum = 0;
            _fracX = 0;
            _fracY = 0;
            _status = "监听中";
        }

        private static double ComputeScaleX(DeviceCache device)
        {
            int screen = GetSystemMetrics(SM_CXSCREEN);
            int range = device.LogicalMaxX > 0 ? device.LogicalMaxX : 1875;
            return (double)screen / range;
        }

        private static double ComputeScaleY(DeviceCache device)
        {
            int screen = GetSystemMetrics(SM_CYSCREEN);
            int range = device.LogicalMaxY > 0 ? device.LogicalMaxY : 1200;
            return (double)screen / range;
        }

        private static void MoveCursor(double dx, double dy)
        {
            _fracX += dx;
            _fracY += dy;
            int stepX = (int)Math.Floor(_fracX);
            int stepY = (int)Math.Floor(_fracY);
            if (stepX == 0 && stepY == 0) return;
            _fracX -= stepX;
            _fracY -= stepY;

            int targetX = _cursorX + stepX;
            int targetY = _cursorY + stepY;
            if (_vWidth > 0)
            {
                if (targetX < _vLeft) targetX = _vLeft;
                if (targetX > _vLeft + _vWidth - 1) targetX = _vLeft + _vWidth - 1;
            }
            if (_vHeight > 0)
            {
                if (targetY < _vTop) targetY = _vTop;
                if (targetY > _vTop + _vHeight - 1) targetY = _vTop + _vHeight - 1;
            }

            _cursorX = targetX;
            _cursorY = targetY;

            double nx = (targetX - _vLeft) * 65535.0;
            double ny = (targetY - _vTop) * 65535.0;
            if (_vWidth > 1) nx /= (_vWidth - 1); else nx = 0;
            if (_vHeight > 1) ny /= (_vHeight - 1); else ny = 0;

            INPUT input = new INPUT();
            input.type = INPUT_MOUSE;
            input.mi.dx = (int)Math.Round(nx);
            input.mi.dy = (int)Math.Round(ny);
            input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        private static void SendMouseButton(bool down)
        {
            INPUT input = new INPUT();
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        // ------------------------------------------------------------------
        // Win32 interop
        // ------------------------------------------------------------------
        private const uint HIDP_STATUS_SUCCESS = 0x00110000;
        private const uint RID_INPUT = 0x10000003;
        private const uint RIDI_PREPARSEDDATA = 0x20000005;
        private const int INPUT_MOUSE = 0;
        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
        private const int SM_CXSCREEN = 0;
        private const int SM_CYSCREEN = 1;
        private const int SM_XVIRTUALSCREEN = 76;
        private const int SM_YVIRTUALSCREEN = 77;
        private const int SM_CXVIRTUALSCREEN = 78;
        private const int SM_CYVIRTUALSCREEN = 79;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WNDCLASSEX
        {
            public uint cbSize;
            public uint style;
            public IntPtr lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
            public IntPtr hIconSm;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICE
        {
            public ushort usUsagePage;
            public ushort usUsage;
            public uint dwFlags;
            public IntPtr hwndTarget;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTHEADER
        {
            public uint dwType;
            public uint dwSize;
            public IntPtr hDevice;
            public IntPtr wParam;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWHID
        {
            public uint dwSizeHid;
            public uint dwCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICELIST
        {
            public IntPtr hDevice;
            public uint dwType;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public int type;
            public MOUSEINPUT mi;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public int mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HIDP_CAPS
        {
            public ushort Usage;
            public ushort UsagePage;
            public ushort InputReportByteLength;
            public ushort OutputReportByteLength;
            public ushort FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
            public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps;
            public ushort NumberInputValueCaps;
            public ushort NumberInputDataIndices;
            public ushort NumberOutputButtonCaps;
            public ushort NumberOutputValueCaps;
            public ushort NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps;
            public ushort NumberFeatureValueCaps;
            public ushort NumberFeatureDataIndices;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HIDP_VALUE_CAPS
        {
            public ushort UsagePage;
            public byte ReportID;
            [MarshalAs(UnmanagedType.U1)] public bool IsAlias;
            public ushort BitField;
            public ushort LinkCollection;
            public ushort LinkUsage;
            public ushort LinkUsagePage;
            [MarshalAs(UnmanagedType.U1)] public bool IsRange;
            [MarshalAs(UnmanagedType.U1)] public bool IsStringRange;
            [MarshalAs(UnmanagedType.U1)] public bool IsDesignatorRange;
            [MarshalAs(UnmanagedType.U1)] public bool IsAbsolute;
            [MarshalAs(UnmanagedType.U1)] public bool HasNull;
            public byte Reserved;
            public ushort BitSize;
            public ushort ReportCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 5)]
            public ushort[] Reserved2;
            public uint UnitsExp;
            public uint Units;
            public int LogicalMin;
            public int LogicalMax;
            public int PhysicalMin;
            public int PhysicalMax;
            public ushort UsageMin;
            public ushort UsageMax;
            public ushort StringMin;
            public ushort StringMax;
            public ushort DesignatorMin;
            public ushort DesignatorMax;
            public ushort DataIndexMin;
            public ushort DataIndexMax;
            public ushort Usage { get { return UsageMin; } }
        }

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWindowExW(uint exStyle, string cls, string name, uint style,
            int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")]
        private static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetMessageW(out MSG msg, IntPtr hwnd, uint min, uint max);
        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG msg);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr DispatchMessageW(ref MSG msg);
        [DllImport("user32.dll")]
        private static extern bool DestroyWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        private static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandleW(string name);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint numDevices, uint cbSize);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetRawInputData(IntPtr hRawInput, uint command, IntPtr data, ref uint size, uint headerSize);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetRawInputDeviceList(IntPtr pRawInputDeviceList, ref uint uiNumDevices, uint cbSize);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint GetRawInputDeviceInfoW(IntPtr hDevice, uint command, IntPtr data, ref uint size);
        [DllImport("hid.dll")]
        private static extern uint HidP_GetCaps(IntPtr preparsedData, out HIDP_CAPS caps);
        [DllImport("hid.dll")]
        private static extern uint HidP_GetValueCaps(uint reportType, [Out] HIDP_VALUE_CAPS[] valueCaps, ref ushort length, IntPtr preparsedData);
        [DllImport("hid.dll")]
        private static extern uint HidP_GetUsageValue(uint reportType, ushort usagePage, ushort linkCollection,
            ushort usage, out uint usageValue, IntPtr preparsedData, IntPtr report, uint reportLength);
        [DllImport("user32.dll")]
        private static extern bool SendInput(uint nInputs, INPUT[] inputs, int cbSize);
        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT pt);
    }
}
