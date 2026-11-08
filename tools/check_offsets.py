#!/usr/bin/env python3
"""Cross-check RSDWServerAPI's hardcoded offsets against a Dumper-7 SDK dump.

Usage: tools/check_offsets.py [RSDWSDK]

Reads src/engine/*.{h,cpp}, resolves each mapped constant against the
CppSDK headers (member comments look like '// 0x02D8(0x0010)(...)') and the
Dumpspace OffsetsInfo.json, and prints OK / MISMATCH / NOT FOUND per constant.
Exit code is 1 if anything mismatched or wasn't found.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "RSDWSDK")
SDKDIR = os.path.join(SDK, "CppSDK", "SDK")

# constant name -> (class or struct name, member name[, extra offset])
MEMBERS = {
    # dom_engine.h
    "UObject_Flags": ("UObject", "Flags"),
    "UObject_Index": ("UObject", "Index"),
    "UObject_Class": ("UObject", "Class"),
    "UObject_Name": ("UObject", "Name"),
    "UObject_Outer": ("UObject", "Outer"),
    "UStruct_SuperStruct": ("UStruct", "SuperStruct"),
    "UClass_ClassDefaultObject": ("UClass", "ClassDefaultObject"),
    "World_PersistentLevel": ("UWorld", "PersistentLevel"),
    "World_AuthorityGameMode": ("UWorld", "AuthorityGameMode"),
    "World_GameState": ("UWorld", "GameState"),
    "GameStateBase_AuthorityGameMode": ("AGameStateBase", "AuthorityGameMode"),
    "GameStateBase_PlayerArray": ("AGameStateBase", "PlayerArray"),
    "DomGameState_bIsDedicatedServer": ("ADominionGameStateBase", "bIsDedicatedServer"),
    "DomGameState_bIsCrossplayEnabled": ("ADominionGameStateBase", "bIsCrossplayEnabled"),
    "DomGameState_KickedUsers": ("ADominionGameStateBase", "KickedUsers"),
    "DomGameState_BannedUsers": ("ADominionGameStateBase", "BannedUsers"),
    "DomGameState_DisplayNameComponent": ("ADominionGameStateBase", "DisplayNameComponent"),
    "DomGameState_WorldHardcoreState": ("ADominionGameStateBase", "WorldHardcoreState"),
    "DisplayName_OriginalCharacterNames": ("UDisplayNameComponent", "OriginalCharacterNames"),
    "CharDisplayName_CharacterGuid": ("FDomCharacterDisplayName", "CharacterGuid"),
    "CharDisplayName_CharacterName": ("FDomCharacterDisplayName", "CharacterName"),
    "CharDisplayName_Size": ("FDomCharacterDisplayName", "@size"),
    "PlayerState_Score": ("APlayerState", "Score"),
    "PlayerState_PlayerId": ("APlayerState", "PlayerId"),
    "PlayerState_CompressedPing": ("APlayerState", "CompressedPing"),
    "PlayerState_Flags": ("APlayerState", "bShouldUpdateReplicatedPing"),
    "PlayerState_StartTime": ("APlayerState", "StartTime"),
    "PlayerState_UniqueID": ("APlayerState", "UniqueID"),
    "PlayerState_PawnPrivate": ("APlayerState", "PawnPrivate"),
    "PlayerState_PlayerName": ("APlayerState", "PlayerNamePrivate"),
    "DomPlayerState_OwnerGuid": ("ADominionPlayerState", "OwnerGuid"),
    "DomPlayerState_PlayerColor": ("ADominionPlayerState", "PlayerColor"),
    "DomPlayerState_PlatformData": ("ADominionPlayerState", "PlatformData"),
    "PlayerColor_Color": ("FPlayerColor", "Color"),
    "PlayerColor_HexString": ("FPlayerColor", "HexString"),
    "PlatformData_UniqueID": ("FDomPlatformData", "UniqueID"),
    "PlatformData_DisplayName": ("FDomPlatformData", "DisplayName"),
    "PlatformData_PlatformName": ("FDomPlatformData", "PlatformName"),
    "NetIdRepl_Size": ("FUniqueNetIdRepl", "@size"),
    "Actor_Owner": ("AActor", "Owner"),
    "Actor_Role": ("AActor", "Role"),
    "Actor_NetDormancy": ("AActor", "NetDormancy"),
    "Actor_RootComponent": ("AActor", "RootComponent"),
    "Pawn_PlayerState": ("APawn", "PlayerState"),
    "Pawn_Controller": ("APawn", "Controller"),
    "Controller_PlayerState": ("AController", "PlayerState"),
    "Controller_Pawn": ("AController", "Pawn"),
    "Character_Mesh": ("ACharacter", "Mesh"),
    "Character_CharacterMovement": ("ACharacter", "CharacterMovement"),
    "SceneComp_RelativeLocation": ("USceneComponent", "RelativeLocation"),
    "SceneComp_RelativeRotation": ("USceneComponent", "RelativeRotation"),
    "MovementComp_Velocity": ("UMovementComponent", "Velocity"),
    "CharMove_MovementMode": ("UCharacterMovementComponent", "MovementMode"),
    "DomPlayerChar_AttributesComponent": ("ADominionPlayerCharacter", "AttributesComponent"),
    "DomPlayerChar_HealthComponent": ("ADominionPlayerCharacter", "HealthComponent"),
    "DomPlayerController_SkillComponent": ("ADominionPlayerControllerBase", "SkillComponent"),
    "Attributes_FloatAttributes": ("UDominionAttributesComponent", "FloatAttributes"),
    "Attributes_SharedFloatAttributes": ("UDominionAttributesComponent", "SharedFloatAttributes"),
    "Attributes_AttributeValues": ("UDominionAttributesComponent", "AttributeValues"),
    "Attributes_SharedAttributeValues": ("UDominionAttributesComponent", "SharedAttributeValues"),
    "Health_MaxHealth": ("UHealthComponent", "MaxHealth"),
    "Health_AuthoritativeHealth": ("UHealthComponent", "AuthoritativeHealth"),
    "Health_bCanDie": ("UHealthComponent", "bCanDie"),
    "SurvivalStat_Current": ("USustenanceComponent", "CurrentSustenance"),
    "SurvivalStat_CurrentMax": ("USustenanceComponent", "CurrentMaxSustenance"),
    "SurvivalStat_DecayBuffer": ("USustenanceComponent", "DecayBuffer"),
    "Skill_Skills": ("USkillComponent", "Skills"),
    "FSkill_CurrentXP": ("FSkill", "CurrentXP"),
    "FSkill_SkillData": ("FSkill", "SkillData"),
    "FSkill_Size": ("FSkill", "@size"),
    "DediSettings_OwnerId": ("UDedicatedServerSettings", "OwnerId"),
    "DediSettings_ServerGuid": ("UDedicatedServerSettings", "ServerGuid"),
    "DediSettings_ServerName": ("UDedicatedServerSettings", "ServerName"),
    "DediSettings_DefaultWorldName": ("UDedicatedServerSettings", "DefaultWorldName"),
    # other files
    "kMaxStackSize": ("UItemData", "MaxStackSize"),
    "kControllerChatComponent": ("ADominionPlayerController", "PlayerChatComponent"),
    "kSenderId": ("FChatPlayerSenderData", "PrimaryNetId"),
    "kSecondaryId": ("FChatPlayerSenderData", "SecondaryNetId"),
    "kCharacterGuid": ("FChatPlayerSenderData", "CharacterGuid"),
    "kPlayerId": ("FChatPlayerSenderData", "PlayerId"),
    "kColor": ("FChatPlayerSenderData", "Color"),
    "kMessageBody": ("FChatMessageData", "MessageBody"),
    "kMessageSize": ("FChatMessageData", "@size"),
    "kEventTag": ("FChatPlayerEventData", "Tag"),
    "kEventSize": ("FChatPlayerEventData", "@size"),
    "kExecFunction": ("UFunction", "ExecFunction"),
    "kFunctionFlags": ("UFunction", "FunctionFlags"),
    "kChildProperties": ("UStruct", "ChildProperties"),
}

IMAGE = {"GObjects": ("OFFSET_GOBJECTS", 0), "GWorld": ("OFFSET_GWORLD", 0),
         # The mod points GNames at FNamePool::CurrentBlock; Dumper-7 stores 8 bytes before it.
         "GNames": ("OFFSET_GNAMES", 8),
         "ProcessEvent": ("OFFSET_PROCESSEVENT", 0),
         "ProcessEventIndex": ("INDEX_PROCESSEVENT", 0)}


def load_sdk():
    """Returns {TypeName: {"@size": n, member: offset}} from every SDK header."""
    types = {}
    head = re.compile(r"^(?:class|struct)\s+(\w+)(?:\s+final)?\s*(?::\s*public\s+(\w+))?\s*$")
    member = re.compile(r"^\s+.*?\b(\w+)(?:\[\w+\])?(?:\s*:\s*\d+)?;\s*//\s*0x([0-9A-Fa-f]+)\(0x([0-9A-Fa-f]+)\)")
    sizecheck = re.compile(r"static_assert\(sizeof\((\w+)\)\s*==\s*0x([0-9A-Fa-f]+)")
    offcheck = re.compile(r"static_assert\(offsetof\((\w+),\s*(\w+)\)\s*==\s*0x([0-9A-Fa-f]+)")
    files = [os.path.join(SDKDIR, f) for f in os.listdir(SDKDIR) if f.endswith((".hpp",))]
    files.append(os.path.join(SDK, "CppSDK", "Assertions.inl"))
    for path in files:
        cur = None
        with open(path, errors="replace") as fh:
            for line in fh:
                m = head.match(line)
                if m:
                    cur = types.setdefault(m.group(1), {})
                    continue
                if line.startswith("};"):
                    cur = None
                    continue
                if cur is not None:
                    m = member.match(line)
                    if m:
                        cur.setdefault(m.group(1), int(m.group(2), 16))
                m = sizecheck.search(line)
                if m:
                    types.setdefault(m.group(1), {})["@size"] = int(m.group(2), 16)
                m = offcheck.search(line)
                if m:
                    types.setdefault(m.group(1), {}).setdefault(m.group(2), int(m.group(3), 16))
    return types


def load_constants():
    consts = {}
    pat = re.compile(r"constexpr\s+\w+\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+)")
    for d, _, fs in os.walk(os.path.join(ROOT, "src", "engine")):
        for f in fs:
            if not f.endswith((".h", ".cpp")):
                continue
            p = os.path.join(d, f)
            for i, line in enumerate(open(p), 1):
                m = pat.search(line)
                if m:
                    consts.setdefault(m.group(1), []).append((int(m.group(2), 16), os.path.relpath(p, ROOT), i))
    return consts


def main():
    types = load_sdk()
    consts = load_constants()
    offsets = dict(json.load(open(os.path.join(SDK, "Dumpspace", "OffsetsInfo.json")))["data"])
    bad = 0

    for name, (key, extra) in IMAGE.items():
        for value, path, line in consts.get(name, []):
            want = offsets[key] + extra
            ok = value == want
            bad += not ok
            print(f"{'OK      ' if ok else 'MISMATCH'} {name:36} {value:#x} -> {want:#x}   {path}:{line}")

    for name, spec in MEMBERS.items():
        typ, mem = spec
        for value, path, line in consts.get(name, []):
            want = types.get(typ, {}).get(mem)
            if want is None:
                bad += 1
                print(f"NOTFOUND {name:36} {value:#x}   ({typ}::{mem})   {path}:{line}")
                continue
            ok = value == want
            bad += not ok
            print(f"{'OK      ' if ok else 'MISMATCH'} {name:36} {value:#x} -> {want:#x}   ({typ}::{mem})   {path}:{line}")

    unchecked = sorted(set(consts) - set(MEMBERS) - set(IMAGE))
    print("\nNot checked (layout constants, not SDK members):", ", ".join(unchecked))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
