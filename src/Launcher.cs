// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ecstasy (https://github.com/xfhrv)

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace TouchpadTunerLauncher
{
    internal static class Program
    {
        private static string AppDirectory
        {
            get { return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); }
        }

        [STAThread]
        private static void Main()
        {
            try
            {
                string dir = AppDirectory;
                string script = Path.Combine(dir, "TouchpadTuner.ps1");
                if (!File.Exists(script))
                {
                    MessageBox.Show(
                        "找不到 TouchpadTuner.ps1。\n请把 TouchpadTuner.exe 与 TouchpadTuner.ps1、app.ico 放在同一个文件夹中。",
                        "触摸板调速器", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(powershell))
                {
                    MessageBox.Show(
                        "找不到 Windows PowerShell，无法启动程序。",
                        "触摸板调速器", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = powershell;
                psi.Arguments = "-NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
                psi.WorkingDirectory = dir;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败：" + ex.Message, "触摸板调速器",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
