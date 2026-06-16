import os, shutil, subprocess, sys
# Paths derive from this script's location (melammu-vn/tools/mirror.py) so the
# default layout (wine-wukiyo as a sibling of melammu-vn) works with no config.
# Override either via env if your layout differs.
_HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.environ.get("WINE_WUKIYO_BUILD", os.path.normpath(os.path.join(_HERE, "..", "..", "wine-wukiyo", "build")))
W     = os.environ.get("MELAMMU_WINE",      os.path.normpath(os.path.join(_HERE, "..", "wine-support", "wine")))
idx_pe={}; idx_pe_i386={}; idx_so={}
for root in (f"{BUILD}/dlls", f"{BUILD}/programs"):
    for dp, dns, fns in os.walk(root):
        if "/tests" in dp: continue
        if dp.endswith("x86_64-windows"):
            for fn in fns: idx_pe.setdefault(fn, os.path.join(dp, fn))
        elif dp.endswith("i386-windows"):
            for fn in fns: idx_pe_i386.setdefault(fn, os.path.join(dp, fn))
        elif dp.count("/") - root.count("/") == 1:
            for fn in fns:
                if fn.endswith(".so"): idx_so.setdefault(fn, os.path.join(dp, fn))
so_done=pe_done=0; kept=[]; missing=[]
# unix .so
d=f"{W}/lib/wine/x86_64-unix"
for n in sorted(os.listdir(d)):
    if not n.endswith(".so"): continue
    if n=="winegstreamer.so": kept.append(n); continue
    src=idx_so.get(n)
    if not src: missing.append(("so",n)); continue
    tmp=os.path.join(d,n+".new"); shutil.copy2(src,tmp)
    subprocess.run(["install_name_tool","-add_rpath","@loader_path/../../",tmp],capture_output=True)
    subprocess.run(["codesign","-f","-s","-",tmp],capture_output=True)
    os.replace(tmp,os.path.join(d,n)); so_done+=1
# x86_64 PE
d=f"{W}/lib/wine/x86_64-windows"
for n in sorted(os.listdir(d)):
    if n in ("winegstreamer.dll","winemetal.dll"): kept.append(n); continue
    src=idx_pe.get(n)
    if not src: missing.append(("pe",n)); continue
    tmp=os.path.join(d,n+".new"); shutil.copy2(src,tmp)
    os.replace(tmp,os.path.join(d,n)); pe_done+=1
# i386 PE (wow64 32bit userland) — must stay same generation as the unix .so layer.
# Each bundle file is overwritten from build/i386-windows; files absent from build are kept as-is.
pe32_done=0; kept_i386=[]
d=f"{W}/lib/wine/i386-windows"
for n in sorted(os.listdir(d)):
    src=idx_pe_i386.get(n)
    if not src: kept_i386.append(n); continue
    tmp=os.path.join(d,n+".new"); shutil.copy2(src,tmp)
    os.replace(tmp,os.path.join(d,n)); pe32_done+=1
# bin
for src,dst in ((f"{BUILD}/loader/wine64",f"{W}/bin/wine"),(f"{BUILD}/server/wineserver",f"{W}/bin/wineserver")):
    tmp=dst+".new"; shutil.copy2(src,tmp)
    subprocess.run(["codesign","-f","-s","-",tmp],capture_output=True)
    os.replace(tmp,dst)
print(f"so_done={so_done} pe_done={pe_done} pe32_done={pe32_done} kept={kept}")
print(f"kept_i386 ({len(kept_i386)} not in build, left as-is):", kept_i386 if kept_i386 else "none")
print("missing:", missing if missing else "none")
sys.exit(1 if missing else 0)
