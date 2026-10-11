Describe 'Linux sentinel authoritative SCSI identity mapping' {
    It 'checks controller and LUN identity independently of the ARM uniqueId scheme' {
        $scriptPath = Join-Path $PSScriptRoot '..\guest\lab-sentinel-linux.sh'
        $python = @'
import ast, contextlib, io, json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
body = source.split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
tree = ast.parse(body)
function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "verify_scsi_identity")
scope = {"json": json}
exec(compile(ast.Module(body=[function], type_ignores=[]), "<identity-check>", "exec"), scope)
verify = scope["verify_scsi_identity"]
disk_id = "/subscriptions/synthetic/resourceGroups/lab/providers/Microsoft.Compute/disks/sentinel"
metadata = {"dataDisks": [{"lun": 0, "managedDisk": {"id": disk_id}}]}
props = {"ID_BUS": "scsi", "AZURE_DISK_TYPE": "data", "AZURE_DISK_LUN": "0", "ID_SERIAL_SHORT": "60022480synthetic"}
verify(metadata, props, "1:0:0:0", disk_id.upper(), props["ID_SERIAL_SHORT"])
cases = [
    (metadata, props, "1:0:0:1", disk_id, props["ID_SERIAL_SHORT"]),
    (metadata, dict(props, ID_BUS="nvme"), "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    (metadata, dict(props, AZURE_DISK_TYPE="os"), "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    (metadata, dict(props, AZURE_DISK_LUN="1"), "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    (metadata, props, "1:0:0:0", disk_id + "-other", props["ID_SERIAL_SHORT"]),
    (metadata, props, "1:0:0:0", disk_id, "unrelated-arm-unique-id"),
    ({"dataDisks": metadata["dataDisks"] * 2}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    (metadata, props, "1:0:0:0", disk_id, ""),
    ({}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ({"dataDisks": []}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ({"dataDisks": [{"lun": "0", "managedDisk": {}}]}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ({"dataDisks": [{"lun": "0", "managedDisk": {"id": ""}}]}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ({"dataDisks": {}}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ({"dataDisks": [None]}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ({"dataDisks": [{"lun": 0, "managedDisk": {"id": 123}}]}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
    ([], props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
]
for args in cases:
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output):
            verify(*args)
    except RuntimeError:
        observed = json.loads(output.getvalue().split("AZVM_DISK_IDENTITY_OBSERVATION=", 1)[1])
        assert observed["storageProfile"] == args[0]
        assert observed["expectedManagedDiskId"] == args[3]
        assert observed["udev"] == args[1]
        assert observed["hctl"] == args[2]
        continue
    raise AssertionError("Ambiguous or wrong identity accepted")
verify({"dataDisks": [{"lun": "0", "managedDisk": {"id": disk_id}}]}, props,
       "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"])
print("2 positive and 16 refusal identity fixtures passed; failure observations preserved")
'@
        $result = $python | python - $scriptPath
        $LASTEXITCODE | Should -Be 0
        ($result -join "`n") | Should -Match '16 refusal'
    }
    It 'uses the kernel bus when NVMe udev ID_BUS and lsblk TRAN are absent' {
        $scriptPath = Join-Path $PSScriptRoot '..\guest\linux-probe.sh'
        $python = @'
import ast, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text().split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
tree = ast.parse(source)
call = next(n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
            and isinstance(n.func.value, ast.Name) and n.func.value.id == "data_mappings" and n.func.attr == "append")
expression = compile(ast.Expression(body=call.args[0]), "<mapping-result>", "eval")
for subsystem, bus, expected in [("scsi", "scsi", "SCSI"), ("nvme", None, "NVMe"), ("unknown", "nvme", "unknown"), ("scsi", None, "unknown")]:
    scope = {"link": pathlib.Path("0"), "device_subsystem": subsystem, "properties": {"ID_BUS": bus}, "members": ["synthetic-uuid"], "mapped": {"tran": None}}
    result = eval(expression, scope)
    assert result == {"lun": 0, "uuids": ["synthetic-uuid"], "controller": expected}, result
print("controller metadata fixtures passed")
'@
        $result = $python | python - $scriptPath
        $LASTEXITCODE | Should -Be 0
        $result | Should -Match 'fixtures passed'
    }
}
