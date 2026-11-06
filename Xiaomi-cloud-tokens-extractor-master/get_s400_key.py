import json
from token_extractor import QrCodeXiaomiCloudConnector, PasswordXiaomiCloudConnector, SERVERS

print("=== Xiaomi S400 (yunmai.scales.ms104 / 34:FA:1C:17:AB:C2) Deep Key Extractor ===")
mode = input("Login method (q = QR Code, p = Password) [q]: ").strip().lower() or "q"

if mode == "p":
    user = input("Xiaomi Account (Email / Phone / ID): ").strip()
    pwd  = input("Password: ").strip()
    conn = PasswordXiaomiCloudConnector(user, pwd)
else:
    conn = QrCodeXiaomiCloudConnector()

if not conn.login():
    print("[-] Login failed.")
    exit(1)

print("[+] Logged in! Scanning all endpoints across servers...")
found_any = False

for srv in ["de", "cn", "sg", "us", "ru", "in", "tw", "i2"]:
    base = conn.get_api_url(srv)
    collected_devices = {}

    # Endpoint 1: Classic /home/device_list (includes standalone BLE & Huami/Yunmai scales)
    r1 = conn.execute_api_call_encrypted(
        base + "/home/device_list",
        {"data": '{"getVirtualModel":true,"getHuamiDevices":1,"get_split_device":true,"support_smart_home":true}'}
    )
    if r1 and "result" in r1 and r1["result"] and "list" in r1["result"]:
        for d in r1["result"]["list"]:
            collected_devices[d.get("did", "")] = d

    # Endpoint 2: /v2/home/device_list_page
    r2 = conn.execute_api_call_encrypted(
        base + "/v2/home/device_list_page",
        {"data": '{"limit":200,"get_split_device":true,"support_smart_home":true}'}
    )
    if r2 and "result" in r2 and r2["result"] and "list" in r2["result"]:
        for d in r2["result"]["list"]:
            collected_devices[d.get("did", "")] = d

    # Endpoint 3: /v2/homeroom/gethome + /v2/home/home_device_list
    homes = conn.get_homes(srv)
    dids_from_homes = []
    if homes and "result" in homes and homes["result"]:
        for h in homes["result"].get("homelist", []):
            hid = h.get("id")
            owner = h.get("uid")
            dids_from_homes.extend(h.get("dids", []))
            for room in h.get("roomlist", []):
                dids_from_homes.extend(room.get("dids", []))
            r3 = conn.get_devices(srv, hid, owner)
            if r3 and "result" in r3 and r3["result"] and r3["result"].get("device_info"):
                for d in r3["result"]["device_info"]:
                    collected_devices[d.get("did", "")] = d

    # If a home listed raw DIDs that weren't in device_info, add them
    for did in set(dids_from_homes):
        if did and did not in collected_devices:
            collected_devices[did] = {"did": did, "name": "Unassigned Home Device", "mac": "UNKNOWN", "model": "UNKNOWN"}

    if collected_devices:
        print(f"\n================ SERVER: {srv.upper()} ================")
        for did, dev in collected_devices.items():
            found_any = True
            name  = dev.get("name", "Unknown")
            mac   = dev.get("mac", "Unknown")
            model = dev.get("model", "Unknown")
            token = dev.get("token", "")
            print(f"  NAME  : {name}")
            print(f"  MODEL : {model}")
            print(f"  MAC   : {mac}")
            print(f"  DID   : {did}")
            if token:
                print(f"  TOKEN : {token}")

            # Always try to fetch BLE beaconkey if it's a blt.* device or scale
            if str(did).startswith("blt.") or "scale" in str(model).lower() or "34:FA:1C" in str(mac).upper():
                bk = conn.get_beaconkey(srv, did)
                if bk and "result" in bk and bk["result"] and "beaconkey" in bk["result"]:
                    key = bk["result"]["beaconkey"]
                    print(f"  >>> BLE BINDKEY (32 HEX) : {key} <<<")
                    with open("../s400_bindkey.txt", "w") as f:
                        f.write(key)
                else:
                    print(f"  BLE Key Response: {bk}")
            print("  ----------------------------------------")

if not found_any:
    print("\n[!] Still no devices found on this Xiaomi Account.")
    print("    1. In Xiaomi Home app on your phone, go to Profile -> look at the 10-digit Xiaomi ID at the top.")
    print("    2. Make sure you scan the QR code from INSIDE the Xiaomi Home app ('+' top right -> Scan)")
    print("       so it logs into the exact same Xiaomi ID that owns the scale!")
