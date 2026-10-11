Describe 'Linux sentinel authoritative SCSI identity mapping' {
    It 'checks controller and LUN identity independently of the ARM uniqueId scheme' {
        $scriptPath = Join-Path $PSScriptRoot '..\guest\lab-sentinel-linux.sh'
        $python = @'
import ast, contextlib, datetime, io, json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
body = source.split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
tree = ast.parse(body)
function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "verify_scsi_identity")
scope = {"json": json, "datetime": datetime}
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
    ({"dataDisks": [], "imageReference": {"id": "", "offer": "ubuntu-24_04-lts", "publisher": "Canonical", "sku": "server", "version": "24.04.202609040"},
      "osDisk": {"diskSizeGB": "64", "managedDisk": {"id": disk_id + "-os", "storageAccountType": "StandardSSD_LRS"}, "osType": "Linux"},
      "resourceDisk": {"size": "0"}}, props, "1:0:0:0", disk_id, props["ID_SERIAL_SHORT"]),
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
    except RuntimeError as error:
        observed = json.loads(output.getvalue().split("AZVM_DISK_IDENTITY_OBSERVATION=", 1)[1])
        assert observed["storageProfile"] == args[0]
        assert observed["expectedManagedDiskId"] == args[3]
        assert observed["udev"] == args[1]
        assert observed["hctl"] == args[2]
        if isinstance(args[0], dict) and args[0].get("dataDisks") == []:
            assert "Exact managed disk identity and unique LUN not confirmed by IMDS" in str(error)
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
    It 'accepts explicit fresh ARM plus Microsoft mapping and refuses contradictory or unsafe evidence' {
        $scriptPath = Join-Path $PSScriptRoot '..\guest\lab-sentinel-linux.sh'
        $python = @'
import ast, contextlib, copy, datetime, io, json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
body = source.split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
function = next(n for n in ast.parse(body).body if isinstance(n, ast.FunctionDef) and n.name == "verify_scsi_identity")
scope = {"json": json, "datetime": datetime}
exec(compile(ast.Module(body=[function], type_ignores=[]), "<identity-check>", "exec"), scope)
verify = scope["verify_scsi_identity"]
prefix = "/subscriptions/synthetic/resourceGroups/azvm-upgrade-lab-offline/providers/Microsoft.Compute/"
disk_id, vm_id, os_id = prefix + "disks/sentinel", prefix + "virtualMachines/testvm", prefix + "disks/os"
serial = "60022480synthetic"
props = {"ID_BUS": "scsi", "AZURE_DISK_TYPE": "data", "AZURE_DISK_LUN": "0", "ID_SERIAL_SHORT": serial}
now = datetime.datetime.now(datetime.timezone.utc)
arm = {"schemaVersion": "lab-arm-identity/1.0", "identityMode": "arm-azure-udev", "labOnly": True,
       "subscriptionId": "synthetic", "testResourceGroup": "azvm-upgrade-lab-offline", "vmName": "testvm",
       "observedAt": now.isoformat(), "expiresAt": (now + datetime.timedelta(hours=1)).isoformat(),
       "expectedScsiSerial": serial,
       "vm": {"id": vm_id, "tags": {"az-vm-upgrade-disposable": "true"}, "properties": {"storageProfile": {
           "diskControllerType": "SCSI", "osDisk": {"managedDisk": {"id": os_id}},
           "dataDisks": [{"lun": 0, "managedDisk": {"id": disk_id}}]}}},
       "disk": {"id": disk_id, "managedBy": vm_id, "tags": {"az-vm-upgrade-disposable": "true"},
                "properties": {"uniqueId": "synthetic-incarnation", "creationData": {"createOption": "Empty"}}}}
metadata = {"dataDisks": [], "osDisk": {"managedDisk": {"id": os_id}}}
verify(metadata, props, "1:0:0:0", disk_id.upper(), serial, "arm-azure-udev", arm)
verify(dict(metadata, dataDisks=[{"lun": "0", "managedDisk": {"id": disk_id}}]), props,
       "1:0:0:0", disk_id, serial, "arm-azure-udev", arm)
cases = [(metadata, props, "1:0:0:0", disk_id, serial, "arm-azure-udev", None),
         (metadata, props, "1:0:0:0", disk_id, serial, "unknown", arm)]
for change in ("stale", "expired", "long-consent", "future", "naive", "not-lab", "scope", "vm", "controller",
               "owner", "provenance", "incarnation", "disk", "tags", "duplicate", "lun", "attached", "os", "serial", "version"):
    a = copy.deepcopy(arm)
    if change == "stale": a["observedAt"] = (now - datetime.timedelta(minutes=11)).isoformat()
    elif change == "expired": a["expiresAt"] = (now - datetime.timedelta(seconds=1)).isoformat()
    elif change == "long-consent": a["expiresAt"] = (now + datetime.timedelta(hours=5)).isoformat()
    elif change == "future": a["observedAt"] = (now + datetime.timedelta(minutes=1)).isoformat()
    elif change == "naive": a["observedAt"] = now.replace(tzinfo=None).isoformat()
    elif change == "not-lab": a["labOnly"] = False
    elif change == "scope": a["testResourceGroup"] = "production"
    elif change == "vm": a["vmName"] = "different"
    elif change == "controller": a["vm"]["properties"]["storageProfile"]["diskControllerType"] = "NVMe"
    elif change == "owner": a["disk"]["managedBy"] = vm_id + "-other"
    elif change == "provenance": a["disk"]["properties"]["creationData"]["createOption"] = "Copy"
    elif change == "incarnation": a["disk"]["properties"]["uniqueId"] = ""
    elif change == "disk": a["disk"]["id"] = disk_id + "-other"
    elif change == "tags": a["disk"]["tags"] = {}
    elif change == "duplicate": a["vm"]["properties"]["storageProfile"]["dataDisks"] *= 2
    elif change == "lun": a["vm"]["properties"]["storageProfile"]["dataDisks"][0]["lun"] = 1
    elif change == "attached": a["vm"]["properties"]["storageProfile"]["dataDisks"][0]["managedDisk"]["id"] = disk_id + "-other"
    elif change == "os": a["vm"]["properties"]["storageProfile"]["osDisk"]["managedDisk"]["id"] = disk_id
    elif change == "serial": a["expectedScsiSerial"] = "different"
    elif change == "version": a["schemaVersion"] = "unknown"
    cases.append((metadata, props, "1:0:0:0", disk_id, serial, "arm-azure-udev", a))
for m in ({}, {"dataDisks": None}, dict(metadata, osDisk={"managedDisk": {"id": os_id + "-other"}}),
          dict(metadata, dataDisks=[{"lun": 0, "managedDisk": {"id": disk_id + "-other"}}]),
          dict(metadata, dataDisks=[{"lun": 1, "managedDisk": {"id": disk_id}}]),
          dict(metadata, dataDisks=[{"lun": 0, "managedDisk": {"id": disk_id}}] * 2),
          dict(metadata, dataDisks=[{"lun": 0, "managedDisk": {"id": disk_id}}, {"lun": 1, "managedDisk": {"id": disk_id + "-other"}}])):
    cases.append((m, props, "1:0:0:0", disk_id, serial, "arm-azure-udev", arm))
for p, h, s in ((dict(props, ID_BUS="nvme"), "1:0:0:0", serial),
                (dict(props, AZURE_DISK_TYPE="os"), "1:0:0:0", serial),
                (dict(props, AZURE_DISK_LUN="1"), "1:0:0:0", serial),
                (props, "1:0:0:1", serial), (props, "1:0:0:0", "changed")):
    cases.append((metadata, p, h, disk_id, s, "arm-azure-udev", arm))
for args in cases:
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output): verify(*args)
    except (RuntimeError, KeyError, ValueError, TypeError):
        observed = json.loads(output.getvalue().split("AZVM_DISK_IDENTITY_OBSERVATION=", 1)[1])
        assert observed["storageProfile"] == args[0]
        expected_arm = {key: args[6].get(key) for key in ("schemaVersion", "identityMode", "observedAt", "expiresAt", "labOnly")} if isinstance(args[6], dict) else args[6]
        assert observed["armEvidence"] == expected_arm
        assert observed["identityMode"] == args[5]
        continue
    raise AssertionError("Unsafe explicit ARM identity accepted")
print("Explicit ARM identity: 2 positive and %d refusal cases; observations preserved" % len(cases))
'@
        $result = $python | python - $scriptPath
        $LASTEXITCODE | Should -Be 0
        ($result -join "`n") | Should -Match 'Explicit ARM identity: 2 positive'
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
    It 'preserves destructive initialization exclusions ahead of any filesystem mutation' {
        $source = Get-Content (Join-Path $PSScriptRoot '..\guest\lab-sentinel-linux.sh') -Raw
        $guards = $source.Substring(0, $source.IndexOf('mkdir -p /var/lib/az-vm-upgrade'))
        foreach ($guard in @(
            'Partitions/children exist; stop', 'Disk is mounted; stop',
            'wipefs --no-act --noheadings --output TYPE', 'Existing disk signatures; never erase them',
            'OS disk exclusion', 'OS disk ancestry exclusion',
            'Existing sentinel; stop rather than overwrite', 'Mount directory is not empty; stop',
            'Existing test mount entry; stop', 'Existing lab fstab backup; preserve it and stop',
            'lsblk serial does not corroborate the captured udev identity',
            'AZVM_INITIALIZE_CONSENT', 'id -u')) {
            $guards | Should -Match ([regex]::Escape($guard))
        }
        $guards | Should -Not -Match '(?m)^(mkfs\.|mount |cp -p |mkdir )'
        $source | Should -Match 'os\.environ\.get\("AZVM_IDENTITY_MODE", "imds-required"\)'
    }
}
