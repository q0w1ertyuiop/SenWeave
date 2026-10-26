"""Exchange real loopback UDP datagrams with aiocoap 0.4.14."""

import asyncio
import argparse
from contextlib import closing
import importlib.metadata
import json
from pathlib import Path
import sqlite3
import tempfile

import aiocoap
import cbor2


async def main(storage_path=None):
    assert importlib.metadata.version("aiocoap") == "0.4.14"
    assert importlib.metadata.version("cbor2") == "5.7.1"
    root = Path(__file__).resolve().parent.parent
    process = await asyncio.create_subprocess_exec(
        "node", "examples/coap/collector.mjs", "--duration-ms", "10000", "--now", "1793000000",
        *(["--store", str(storage_path)] if storage_path else []),
        cwd=root, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    context = None
    try:
        startup = json.loads(await asyncio.wait_for(process.stdout.readline(), timeout=5))
        assert startup["kind"] == "listening"
        # simple6 is aiocoap's portable connected-UDP client transport.
        context = await aiocoap.Context.create_client_context(transports=["simple6"])
        base = f"coap://127.0.0.1:{startup['port']}"

        async def post(payload, content_format, path="/ingest"):
            request = aiocoap.Message(code=aiocoap.POST, uri=base + path, payload=payload)
            if content_format is not None:
                request.opt.content_format = content_format
            return await asyncio.wait_for(context.request(request).response, timeout=3)

        valid = b'[{"bn":"external:","bv":20},{"n":"temperature","v":2.5,"t":-3}]'
        assert (await post(valid, 110)).code == aiocoap.CHANGED
        binary = cbor2.dumps([{0: "blob", 8: b"\xfb\xef\xbe\xff\xff\xff", 6: 0}], canonical=True)
        assert (await post(binary, 112)).code == aiocoap.CHANGED
        assert (await post(b"[]", 50)).code == aiocoap.UNSUPPORTED_CONTENT_FORMAT
        assert (await post(b"[]", None)).code == aiocoap.UNSUPPORTED_CONTENT_FORMAT
        assert (await post(b"[]", 110, "/other")).code == aiocoap.NOT_FOUND
        invalid = await post(b"\xff", 110)
        assert invalid.code == aiocoap.BAD_REQUEST and invalid.payload == b"InvalidUtf8"
        strict = await post(b'[{"n":"x","v":1,"vendor":1}]', 110)
        assert strict.code == aiocoap.BAD_REQUEST and strict.payload == b"IgnoredExtensions"
        if storage_path:
            with closing(sqlite3.connect(storage_path)) as database:
                accepted = [json.loads(row[0]) for row in database.execute("SELECT senml_json FROM measurements ORDER BY id")]
        else:
            accepted = []
            while len(accepted) < 2:
                event = json.loads(await asyncio.wait_for(process.stdout.readline(), timeout=2))
                if event["kind"] == "accepted":
                    accepted.append(json.loads(event["json"]))
        assert accepted == [
            [{"n": "external:temperature", "t": 1792999997, "v": 22.5}],
            [{"n": "blob", "t": 1793000000, "vd": "----____"}],
        ]
        print(json.dumps({"peer": "aiocoap==0.4.14", "transport": "loopback-udp4", "mode": "sqlite-after-commit" if storage_path else "validation", "exchanges": 7, "accepted": 2, "status": "passed"}))
    finally:
        if context is not None:
            await context.shutdown()
        if process.returncode is None:
            process.terminate()
        await asyncio.wait_for(process.communicate(), timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--storage", action="store_true", help="Verify SQLite commit before a separate CoAP success response")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="senweave-coap-peer-") as directory:
        asyncio.run(main(Path(directory) / "measurements.sqlite" if args.storage else None))
