# Golden validation of the committed .agbf font packs — the exact bytes the installer ships.
#
# These are generated (fonts/generate.py in the agwinterm repo, .agbf v1, little-endian) and then
# COMMITTED, so the thing that can go wrong is a corrupted regeneration slipping into a release: a
# truncated atlas, an index that is no longer sorted, a family that quietly lost its Cyrillic. None
# of that is visible until a glyph fails to draw on a user's screen, so it is checked here instead.
#
# It came from agwinterm's AgbfPackTests.cs and moved with the assets when lite became agliteterm.
# The parsing and CRC-32 are still compiled C# rather than rewritten in PowerShell — the logic is
# the value, and a hand-reimplementation is exactly how a golden check stops matching the format it
# is supposed to be guarding.
param(
    [string]$Assets = "$PSScriptRoot\..\assets",
    # Accepted so run-all can pass it uniformly; nothing here can skip.
    [string]$Exe,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" }
    else { $script:fail++; "  FAIL  $name$(if ($detail) { " — $detail" })" }
}

"== agbf packs =="

Add-Type -TypeDefinition @'
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Text;

public struct AgbfRec {
    public uint Cp, Off; public short Bx, By; public ushort W, H; public byte CellW, Flags;
}

public class AgbfPack {
    public int Strike; public ushort CellW, CellH, Baseline;
    public uint AtlasOff, AtlasLen; public string Family;
    public AgbfRec[] Recs;
    public List<string> Problems = new List<string>();

    static uint Crc32(byte[] data, int start) {
        uint crc = 0xFFFFFFFFu;
        for (int i = start; i < data.Length; i++) {
            crc ^= data[i];
            for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (uint)-(crc & 1));
        }
        return ~crc;
    }

    // Structural load. Anything wrong is COLLECTED rather than thrown, so one broken pack reports
    // everything wrong with it instead of only whatever tripped first.
    public static AgbfPack Load(string path) {
        var p = new AgbfPack();
        var b = File.ReadAllBytes(path);
        if (b.Length <= 172) { p.Problems.Add("truncated header"); return p; }
        if (Encoding.ASCII.GetString(b, 0, 4) != "AGBF") p.Problems.Add("bad magic");
        if (BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 4, 4)) != 1u) p.Problems.Add("not format v1");
        p.Strike   = (int)BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 8, 4));
        p.CellW    = BinaryPrimitives.ReadUInt16LittleEndian(new ReadOnlySpan<byte>(b, 12, 2));
        p.CellH    = BinaryPrimitives.ReadUInt16LittleEndian(new ReadOnlySpan<byte>(b, 14, 2));
        p.Baseline = BinaryPrimitives.ReadUInt16LittleEndian(new ReadOnlySpan<byte>(b, 16, 2));
        uint count      = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 24, 4));
        uint recordsOff = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 28, 4));
        p.AtlasOff = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 32, 4));
        p.AtlasLen = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 36, 4));
        uint crc   = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, 40, 4));
        p.Family = Encoding.UTF8.GetString(b, 44, 64).TrimEnd('\0');

        if (recordsOff != 172u) p.Problems.Add("recordsOff " + recordsOff + " != 172");
        if (p.AtlasOff != 172u + count * 20u) p.Problems.Add("atlasOff does not follow the index");
        if ((long)p.AtlasOff + p.AtlasLen != b.LongLength) p.Problems.Add("atlas length does not reach end of file");
        if (crc != Crc32(b, 172)) p.Problems.Add("CRC-32 mismatch");

        p.Recs = new AgbfRec[count];
        for (int i = 0; i < count; i++) {
            int o = (int)recordsOff + i * 20;
            p.Recs[i].Cp    = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, o, 4));
            p.Recs[i].Off   = BinaryPrimitives.ReadUInt32LittleEndian(new ReadOnlySpan<byte>(b, o + 4, 4));
            p.Recs[i].Bx    = BinaryPrimitives.ReadInt16LittleEndian(new ReadOnlySpan<byte>(b, o + 8, 2));
            p.Recs[i].By    = BinaryPrimitives.ReadInt16LittleEndian(new ReadOnlySpan<byte>(b, o + 10, 2));
            p.Recs[i].W     = BinaryPrimitives.ReadUInt16LittleEndian(new ReadOnlySpan<byte>(b, o + 12, 2));
            p.Recs[i].H     = BinaryPrimitives.ReadUInt16LittleEndian(new ReadOnlySpan<byte>(b, o + 14, 2));
            p.Recs[i].CellW = b[o + 16];
            p.Recs[i].Flags = b[o + 17];
        }
        return p;
    }

    public string CheckStructure(int strike, bool complete) {
        var bad = new List<string>(Problems);
        if (Strike != strike) bad.Add("strike " + Strike + " != " + strike);
        string want = complete ? "AGWin Bitmap Complete" : "AGWin Bitmap";
        if (Family != want) bad.Add("family '" + Family + "' != '" + want + "'");
        if (CellW < 1 || CellW > 64) bad.Add("cellW " + CellW + " out of range");
        if (CellH <= CellW) bad.Add("cell is not taller than wide");
        if (Baseline < 1 || Baseline > CellH) bad.Add("baseline " + Baseline + " out of range");
        for (int i = 1; i < Recs.Length; i++)
            if (Recs[i - 1].Cp >= Recs[i].Cp) { bad.Add("index not strictly sorted at #" + i); break; }
        foreach (var r in Recs) {
            if (r.CellW != 1 && r.CellW != 2) { bad.Add(Cp(r.Cp) + ": cellWidth " + r.CellW); break; }
            long stride = (r.Flags & 16) != 0 ? r.W * 4 : (r.Flags & 2) != 0 ? (r.W + 7) / 8 : r.W;
            if (r.Off + stride * r.H > AtlasLen) { bad.Add(Cp(r.Cp) + ": atlas overrun"); break; }
        }
        return bad.Count == 0 ? null : string.Join("; ", bad);
    }

    // The coverage each family PROMISES. A pack that parses cleanly but lost its box-drawing or its
    // Cyrillic is still a broken release, and only a content check catches that.
    public string CheckCoverage(bool complete) {
        var bad = new List<string>();
        var by = new Dictionary<uint, AgbfRec>();
        foreach (var r in Recs) by[r.Cp] = r;

        foreach (uint cp in new uint[] { 0x2500, 0x2502, 0x2554, 0x253C, 0x2588, 0x2591, 0xE0B0, 0x0410, 0x044F, 0xFFFD })
            if (!by.ContainsKey(cp)) bad.Add("missing required glyph " + Cp(cp));
        foreach (uint cp in new uint[] { 0x2500, 0x2588, 0xE0B0 })
            if (by.ContainsKey(cp) && (by[cp].Flags & 1) != 1) bad.Add(Cp(cp) + " not synthesized from cell geometry");

        if (!complete) {
            foreach (var r in Recs) {
                if (r.CellW != 1) { bad.Add("curated family has a wide glyph " + Cp(r.Cp)); break; }
                if ((r.Flags & 2) != 0) { bad.Add("curated family is not all 8-bit at " + Cp(r.Cp)); break; }
            }
            return bad.Count == 0 ? null : string.Join("; ", bad);
        }

        // Complete: BMP fallback — CJK/kana/hangul wide 1-bit Unifont, Hebrew/IPA narrow.
        var fallback = new Dictionary<uint, byte> { {0x4E2D,2}, {0x3042,2}, {0xAC00,2}, {0x05D0,1}, {0x0250,1} };
        foreach (var kv in fallback) {
            AgbfRec r;
            if (!by.TryGetValue(kv.Key, out r)) { bad.Add("missing fallback glyph " + Cp(kv.Key)); continue; }
            if (r.CellW != kv.Value) bad.Add(Cp(kv.Key) + ": cellWidth " + r.CellW + " != " + kv.Value);
            if ((r.Flags & 2) != 2) bad.Add(Cp(kv.Key) + ": not 1-bit");
            if ((r.Flags & 4) != 4) bad.Add(Cp(kv.Key) + ": not marked fallback");
        }
        // Emoji: colour records (BGRA, flag 16) spanning two cells.
        foreach (uint cp in new uint[] { 0x1F600, 0x1F680, 0x1F4A9 }) {
            AgbfRec r;
            if (!by.TryGetValue(cp, out r)) { bad.Add("missing emoji " + Cp(cp)); continue; }
            if ((r.Flags & 16) != 16) bad.Add(Cp(cp) + ": not a colour record");
            if (r.CellW != 2) bad.Add(Cp(cp) + ": emoji must span two cells");
        }
        return bad.Count == 0 ? null : string.Join("; ", bad);
    }

    static string Cp(uint cp) { return "U+" + cp.ToString("X4"); }
}
'@

# Glyphs must FIT the cells they claim. The renderer clips at the cell edge, so a record that
# overruns arrives on screen cut in half — U+23FA used to render as a half circle.
#
# This was a ratchet over a known-bad state (2671 overflowing records in bitmap-14 alone). The packs
# were then regenerated with fonts/generate.py fitting each glyph at rasterization time, so the
# budget is now ZERO and stays there: the generator asserts the same invariant, and this is the
# check that catches a pack built by an older generator being committed by hand.
$overflowBudget = 0

$packs = @(
    @{ Name = 'agwin-bitmap-14.agbf';          Strike = 14; Complete = $false }
    @{ Name = 'agwin-bitmap-16.agbf';          Strike = 16; Complete = $false }
    @{ Name = 'agwin-bitmap-18.agbf';          Strike = 18; Complete = $false }
    @{ Name = 'agwin-bitmap-20.agbf';          Strike = 20; Complete = $false }
    @{ Name = 'agwin-bitmap-complete-14.agbf'; Strike = 14; Complete = $true }
    @{ Name = 'agwin-bitmap-complete-16.agbf'; Strike = 16; Complete = $true }
    @{ Name = 'agwin-bitmap-complete-18.agbf'; Strike = 18; Complete = $true }
    @{ Name = 'agwin-bitmap-complete-20.agbf'; Strike = 20; Complete = $true }
)

foreach ($p in $packs) {
    $path = Join-Path $Assets $p.Name
    if (-not (Test-Path $path)) { Check "$($p.Name)" $false 'not committed'; continue }
    $pack = [AgbfPack]::Load($path)
    $why = $pack.CheckStructure($p.Strike, $p.Complete)
    Check ("{0,-30} structure" -f $p.Name) ($null -eq $why) $why
    $why = $pack.CheckCoverage($p.Complete)
    Check ("{0,-30} coverage" -f $p.Name) ($null -eq $why) $why

    $over = 0
    foreach ($r in $pack.Recs) {
        if ($r.W -eq 0) { continue }
        if (($r.Bx + $r.W) -gt ($r.CellW * $pack.CellW) -or $r.Bx -lt 0) { $over++ }
    }
    Check ("{0,-30} every glyph fits its cell" -f $p.Name) ($over -eq $overflowBudget) "$over glyphs overflow"
}

if ($fail) { "agbf-packs: $fail FAILED"; exit 1 }
"agbf-packs: all passed"
exit 0
