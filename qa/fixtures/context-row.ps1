# qa/persistence.md - "The context is drawn dimmed after the name". Drives a sandbox, captures the
# window with PrintWindow before and after `session context`, and reports the bounding box of what
# changed, so the assertion is on the world: one row changed, to the right of its label, and the
# pennant / unread pill pixels are identical in both captures.
#
# Usage: pwsh qa\fixtures\context-row.ps1 [-Out <dir>]   (writes before.png, after.png, sidebar.png)
param([string]$Out = (Join-Path $env:TEMP 'agliteterm-context-row'), [string]$Exe)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'test\ui-lib.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class RowCap {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr sec, uint off);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant; public uint colors;
    }
    // Plain GDI into a top-down 32bpp DIB, then one copy into the Bitmap: pwsh 7's System.Drawing
    // keeps Graphics behind a private assembly Add-Type cannot reference.
    public static Bitmap Capture(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        int w = r.R - r.L, hgt = r.B - r.T;
        var bi = new BITMAPINFO(); bi.biSize = 40; bi.biWidth = w; bi.biHeight = -hgt; bi.biPlanes = 1; bi.biBitCount = 32;
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), bits;
        IntPtr dib = CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
        IntPtr old = SelectObject(mem, dib);
        PrintWindow(h, mem, 2);   // PW_RENDERFULLCONTENT
        var bmp = new Bitmap(w, hgt, PixelFormat.Format32bppArgb);
        var d = bmp.LockBits(new Rectangle(0, 0, w, hgt), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var row = new int[w];
        for (int y = 0; y < hgt; y++) { Marshal.Copy(bits + y * w * 4, row, 0, w); Marshal.Copy(row, 0, d.Scan0 + y * d.Stride, w); }
        bmp.UnlockBits(d);
        SelectObject(mem, old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        return bmp;
    }
    /// <summary>Bounding box of every pixel that differs; null when identical.</summary>
    public static int[] Diff(Bitmap a, Bitmap b) {
        int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1, n = 0;
        var ra = a.LockBits(new Rectangle(0, 0, a.Width, a.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var rb = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int w = Math.Min(a.Width, b.Width), hgt = Math.Min(a.Height, b.Height);
            var pa = new int[w]; var pb = new int[w];
            for (int y = 0; y < hgt; y++) {
                Marshal.Copy(ra.Scan0 + y * ra.Stride, pa, 0, w);
                Marshal.Copy(rb.Scan0 + y * rb.Stride, pb, 0, w);
                for (int x = 0; x < w; x++) if (pa[x] != pb[x]) {
                    n++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
                }
            }
        } finally { a.UnlockBits(ra); b.UnlockBits(rb); }
        return n == 0 ? null : new[] { x0, y0, x1, y1, n };
    }
    /// <summary>Count of pixels in the rect whose colour is within tol of c (per channel).</summary>
    public static int CountNear(Bitmap a, int x0, int y0, int x1, int y1, Color c, int tol) {
        int n = 0;
        for (int y = Math.Max(0, y0); y < Math.Min(a.Height, y1); y++)
            for (int x = Math.Max(0, x0); x < Math.Min(a.Width, x1); x++) {
                var p = a.GetPixel(x, y);
                if (Math.Abs(p.R - c.R) <= tol && Math.Abs(p.G - c.G) <= tol && Math.Abs(p.B - c.B) <= tol) n++;
            }
        return n;
    }
}
'@ -ReferencedAssemblies @([System.Drawing.Bitmap].Assembly.Location, [System.Drawing.Color].Assembly.Location, 'System.Runtime.InteropServices')

New-Item -ItemType Directory -Force $Out | Out-Null
$ctl = Get-CtlPath
$exe = Resolve-Lite $Exe
if (-not $exe) { throw 'bin\agliteterm.exe not built' }
$s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe 'qa-ctxrow'
try {
    function Tree { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
    function Sessions { Tree | ForEach-Object workspaces | ForEach-Object sessions }
    $a = [string](Sessions | Select-Object -First 1).id
    Send-Ctl $s @('session', 'rename', 'alpha', '--target', $a) | Out-Null
    $b = [string](Get-CtlResult $s @('session', 'new', '--name', 'beta'))
    $c = [string](Get-CtlResult $s @('session', 'new', '--name', 'gamma'))
    Start-Sleep 3
    # alpha gets every badge: the flag, and an unread count (a command that finishes while beta
    # is on screen - the FTCS wrap marks it done, and alpha is not visible).
    Send-Ctl $s @('session', 'select', '--target', $b) | Out-Null
    Send-Ctl $s @('session', 'flag', 'on', '--target', $a) | Out-Null
    Send-Ctl $s @('session', 'type', "echo one`r", '--target', $a) | Out-Null
    Start-Sleep 3
    $unread = (Sessions | Where-Object id -eq $a).unread
    Write-Host "alpha unread=$unread flagged=$((Sessions | Where-Object id -eq $a).flagged)"

    $before = [RowCap]::Capture($s.Hwnd)
    $before.Save((Join-Path $Out 'before.png'))

    $r1 = Send-Ctl $s @('session', 'context', 'reviewing the P3 diff', '--target', $a)
    $r2 = Send-Ctl $s @('session', 'context', 'a context long enough that it cannot fit in a 180 px sidebar row and must be cut with an ellipsis', '--target', $c)
    Write-Host "set: $r1`nset: $r2"
    Start-Sleep 2
    $after = [RowCap]::Capture($s.Hwnd)
    $after.Save((Join-Path $Out 'after.png'))

    # The sidebar corner, enlarged 2x for the doc.
    $crop = $after.Clone([System.Drawing.Rectangle]::new(0, 0, 260, 170), $after.PixelFormat)
    $big = New-Object System.Drawing.Bitmap (520, 340)
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.DrawImage($crop, 0, 0, 520, 340); $g.Dispose()
    $big.Save((Join-Path $Out 'sidebar.png')); $big.Dispose(); $crop.Dispose()

    $d = [RowCap]::Diff($before, $after)
    if ($d) { Write-Host ("diff bbox: x {0}..{1}  y {2}..{3}  ({4} px)" -f $d[0], $d[2], $d[1], $d[3], $d[4]) }
    else { Write-Host 'diff: captures identical (the context drew nothing)' }
    # Amber pennant pixels, in the whole image, before and after: the same count in the same place.
    $amber = [System.Drawing.Color]::FromArgb(245, 194, 66)
    $red = [System.Drawing.Color]::FromArgb(205, 72, 58)
    $ba = [RowCap]::CountNear($before, 0, 0, 300, 250, $amber, 6); $aa = [RowCap]::CountNear($after, 0, 0, 300, 250, $amber, 6)
    $br = [RowCap]::CountNear($before, 0, 0, 300, 250, $red, 6);   $ar = [RowCap]::CountNear($after, 0, 0, 300, 250, $red, 6)
    Write-Host "pennant px before/after: $ba/$aa   pill px before/after: $br/$ar"
    # The two badges' own pixels did not change at all: diff restricted to the badge strip.
    $strip = [RowCap]::Diff($before.Clone([System.Drawing.Rectangle]::new(0, 0, 300, 250), $before.PixelFormat),
                            $after.Clone([System.Drawing.Rectangle]::new(0, 0, 300, 250), $after.PixelFormat))
    if ($strip) { Write-Host ("sidebar diff bbox: x {0}..{1}  y {2}..{3}  ({4} px)" -f $strip[0], $strip[2], $strip[1], $strip[3], $strip[4]) }
    Write-Host "tree: $(Send-Ctl $s @('tree'))"
    Write-Host "out: $Out"
} finally {
    Stop-Sandbox $s
}
