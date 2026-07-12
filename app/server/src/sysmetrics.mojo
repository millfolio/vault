"""sysmetrics — GPU / memory / disk stat readers for the status bar + catalog.

Cheap, stateless samples read WITHOUT root via short `ioreg`/`sysctl`/`vm_stat`/
`df` shell pipelines to a temp file in the data dir (same subprocess-to-temp-file
pattern throughout). Each returns -1 when unavailable so the UI can hide the
indicator. Plus `_dir_size`, the recursive byte-size walk the System page uses.

Split for testability (Phase-1 tail): the FETCH side (`_sample_int` — run the
pipeline, read its temp file) is a thin shell wrapper; the PARSE side
(`_parse_leading_int`) is pure and unit-tested (test/sysmetrics_test.mojo).
Each reader is now just "build the pipeline → `_sample_int`".

Depends only on `osutil` (`_config_dir`, `_cstr`) + the stdlib — no import cycle.
Behaviour is identical to the pre-split readers.
"""

from std.ffi import external_call
from std.os import listdir
from std.os.path import isfile, isdir, getsize

from osutil import _config_dir, _cstr


def _parse_leading_int(s: String) -> Int:
    """The FIRST run of ASCII digits in `s` as a non-negative Int; -1 when `s`
    contains no digit. Pure — the parse half of every sampler below (their
    pipelines emit a single integer, possibly with surrounding whitespace)."""
    var cur = 0
    var indig = False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            cur = cur * 10 + (c - 48)
            indig = True
        elif indig:
            break
    return cur if indig else -1


def _sample_int(cmd: String, out_path: String) -> Int:
    """The FETCH half: run the shell pipeline `cmd` (which redirects its single
    integer into `out_path`), read the file back, and parse. Returns -1 on any
    failure (spawn, read, or no digits) so callers can hide the indicator."""
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    try:
        var s: String
        with open(out_path, "r") as f:
            s = f.read()
        return _parse_leading_int(s)
    except:
        return -1


def _gpu_util_pct() -> Int:
    """Instantaneous GPU utilization (%), read WITHOUT root from IOKit's
    IOAccelerator `PerformanceStatistics` via `ioreg`. A shell pipeline extracts
    the single "Device Utilization %" integer to a temp file we then read.
    Returns -1 when unavailable (non-Apple-GPU host / parse miss) so the bar can
    hide the indicator. The 30-second rolling average is kept CLIENT-side (the
    bottom bar polls this), so a sample stays cheap + stateless."""
    var out_path = _config_dir() + "/.gpu_util"
    # `cd /` first: if a deploy wiped the process's working dir (the bundle tree is
    # re-unpacked on `mill install`), the spawned shell would otherwise spam
    # "shell-init: getcwd: cannot access parent directories" on every poll.
    var cmd = (
        String(
            "cd / 2>/dev/null; ioreg -r -d 1 -c IOAccelerator 2>/dev/null | "
        )
        + "sed -n 's/.*\"Device Utilization %\"=\\([0-9][0-9]*\\).*/\\1/p' | "
        + "head -1 > '"
        + out_path
        + "' 2>/dev/null"
    )
    return _sample_int(cmd, out_path)


def _memory_gb() -> Int:
    """Total physical RAM in whole GB, read via `sysctl -n hw.memsize` (bytes) —
    same subprocess-to-temp-file pattern as `_gpu_util_pct`. Used by the model
    catalog UI to gray out checkpoints too big to fit in memory. Returns -1 when
    unavailable (non-macOS / parse miss) so the client falls back to enabling all
    models. RAM is fixed for a machine, but /api/models is polled rarely (only when
    the catalog popover opens), so a per-call sample is cheap enough — no caching.
    """
    var out_path = _config_dir() + "/.mem_bytes"
    # `cd /` first (see `_gpu_util_pct`): a re-unpacked bundle can leave the spawned
    # shell with no valid cwd, which otherwise spams a getcwd warning.
    var cmd = (
        String("cd / 2>/dev/null; sysctl -n hw.memsize > '")
        + out_path
        + "' 2>/dev/null"
    )
    var bytes = _sample_int(cmd, out_path)
    if bytes < 0:
        return -1
    # Bytes → GiB (macOS reports hw.memsize as a power-of-two capacity, e.g.
    # a "24 GB" Mac is 25769803776 = 24 * 1024^3). Round to nearest whole GB.
    return (bytes + (1 << 29)) >> 30


def _memory_used_pct() -> Int:
    """Instantaneous system memory-used % — App + Wired + Compressed over the total
    resident pages, from `vm_stat` (same subprocess-to-temp-file pattern as
    `_gpu_util_pct`; the bottom bar polls it beside the GPU sample). Returns -1 when
    unavailable so the bar can hide the indicator."""
    var out_path = _config_dir() + "/.mem_used"
    # `cd /` first (see `_gpu_util_pct`): guard against a wiped cwd after a re-unpack.
    var cmd = (
        String("cd / 2>/dev/null; vm_stat 2>/dev/null | awk '")
        + '/^Pages free/{v=$NF;gsub(/\\./,"",v);free=v}'
        + '/^Pages active/{v=$NF;gsub(/\\./,"",v);active=v}'
        + '/^Pages inactive/{v=$NF;gsub(/\\./,"",v);inactive=v}'
        + '/^Pages speculative/{v=$NF;gsub(/\\./,"",v);spec=v}'
        + '/^Pages wired/{v=$NF;gsub(/\\./,"",v);wired=v}'
        + '/occupied by compressor/{v=$NF;gsub(/\\./,"",v);comp=v}'
        + "END{total=free+active+inactive+spec+wired+comp;"
        + 'if(total>0)printf "%d",((active+wired+comp)*100/total)}'
        + "' > '"
        + out_path
        + "' 2>/dev/null"
    )
    return _sample_int(cmd, out_path)


def _disk_used_pct() -> Int:
    """Instantaneous disk-used % of the volume holding the vault + models (`df -P` on
    the data dir, so it reflects the disk the index/weights live on; same subprocess-
    to-temp-file pattern as `_memory_used_pct`). Returns -1 when unavailable so the bar
    can hide the indicator."""
    var out_path = _config_dir() + "/.disk_used"
    # `cd /` first (see `_gpu_util_pct`): guard against a wiped cwd after a re-unpack.
    var cmd = (
        String("cd / 2>/dev/null; df -P '")
        + _config_dir()
        + "' 2>/dev/null | awk '"
        + 'NR==2{v=$5;gsub(/%/,"",v);printf "%d",v}'
        + "' > '"
        + out_path
        + "' 2>/dev/null"
    )
    return _sample_int(cmd, out_path)


def _dir_size(path: String) -> Int:
    """Recursive byte size of a file or directory tree (0 if missing)."""
    try:
        if isfile(path):
            return getsize(path)
        if isdir(path):
            var total = 0
            var entries = listdir(path)
            for i in range(len(entries)):
                total += _dir_size(path + "/" + String(entries[i]))
            return total
    except:
        pass
    return 0
