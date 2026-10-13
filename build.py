"""Inject the compiled ABI/bytecode (and deployed address, if given) into the web page.
Usage: python3 build.py [LEASH_ADDRESS] [DEPLOY_BLOCK]"""
import json, sys, pathlib
root = pathlib.Path(__file__).parent
art = json.loads((root / "out/Leash.sol/Leash.json").read_text())
html = (root / "web/index.src.html").read_text()
addr = sys.argv[1] if len(sys.argv) > 1 else ""
block = sys.argv[2] if len(sys.argv) > 2 else "0"
html = (html.replace("__ABI__", json.dumps(art["abi"]))
            .replace("__BYTECODE__", art["bytecode"]["object"])
            .replace("__LEASH_ADDRESS__", addr)
            .replace("__DEPLOY_BLOCK__", str(int(block))))
(root / "docs/index.html").write_text(html)
(root / "docs/abi.json").write_text(json.dumps(art["abi"], indent=1))
print("wrote docs/index.html", "address:", addr or "(none, deploy from the page)")
