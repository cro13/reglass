"""Read the Bloks function maps from a straight-line DEX class initializer."""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass

MIN_FUNCTIONS = 300
TABLE_NAME = "bloks-functions.txt"
_HASH_MAP = b"Ljava/util/HashMap;"
_MAP_TYPES = (_HASH_MAP, b"Ljava/util/AbstractMap;", b"Ljava/util/Map;")
_INTEGER = b"Ljava/lang/Integer;"
_OBJECT = b"Ljava/lang/Object;"
_FUNCTION_NAME = re.compile(rb"[A-Za-z_][A-Za-z0-9_.-]*")


class TableError(ValueError):
    """An extraction error with no DEX strings in its diagnostic."""


@dataclass(frozen=True)
class _BoxedInt:
    value: int


def _signed(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


class _Dex:
    def __init__(self, data: bytes):
        self.data = data
        size, header_size, endian = struct.unpack_from("<III", data, 32)
        if size != len(data) or header_size != 112 or endian != 0x12345678:
            raise ValueError("unsupported or truncated DEX header")
        (self.strings_count, self.strings_at, self.types_count, self.types_at,
         self.protos_count, self.protos_at, self.fields_count, self.fields_at,
         self.methods_count, self.methods_at, self.classes_count, self.classes_at) = struct.unpack_from("<12I", data, 56)
        self.strings: dict[int, bytes] = {}

    def uint(self, at: int) -> int:
        return struct.unpack_from("<I", self.data, at)[0]

    def uleb(self, at: int) -> tuple[int, int]:
        value = 0
        for shift in range(0, 35, 7):
            byte = self.data[at]
            at += 1
            value |= (byte & 0x7F) << shift
            if byte < 0x80 and value <= 0xFFFFFFFF:
                return value, at
        raise ValueError("invalid DEX ULEB128")

    def string(self, index: int) -> bytes:
        if index not in self.strings:
            if index >= self.strings_count:
                raise ValueError("invalid DEX string index")
            offset = self.uint(self.strings_at + 4 * index)
            _, start = self.uleb(offset)
            self.strings[index] = self.data[start:self.data.index(0, start)]
        return self.strings[index]

    def type(self, index: int) -> bytes:
        if index >= self.types_count:
            raise ValueError("invalid DEX type index")
        return self.string(self.uint(self.types_at + 4 * index))

    def method(self, index: int) -> tuple[bytes, bytes, bytes, tuple[bytes, ...]]:
        if index >= self.methods_count:
            raise ValueError("invalid DEX method index")
        owner, proto, name = struct.unpack_from("<HHI", self.data, self.methods_at + 8 * index)
        if proto >= self.protos_count:
            raise ValueError("invalid DEX prototype index")
        _, result, params_at = struct.unpack_from("<III", self.data, self.protos_at + 12 * proto)
        params = ()
        if params_at:
            indices = struct.unpack_from(f"<{self.uint(params_at)}H", self.data, params_at + 4)
            params = tuple(self.type(index) for index in indices)
        return self.type(owner), self.string(name), self.type(result), params

    def initializers(self):
        """Yield code and field IDs for classes with two static HashMap fields."""
        for index in range(self.classes_count):
            class_at = self.classes_at + index * 32
            at = self.uint(class_at + 24)  # class_data_off
            if not at:
                continue
            static_count, at = self.uleb(at)
            if static_count < 2:
                continue
            instance_count, at = self.uleb(at)
            direct_count, at = self.uleb(at)
            _, at = self.uleb(at)  # virtual_methods_size
            fields = set()
            field = 0
            for _ in range(static_count):
                diff, at = self.uleb(at)
                _, at = self.uleb(at)  # access_flags
                field += diff
                if field >= self.fields_count:
                    raise ValueError("invalid DEX field index")
                _, field_type, _ = struct.unpack_from("<HHI", self.data, self.fields_at + 8 * field)
                if self.type(field_type) == _HASH_MAP:
                    fields.add(field)
            if len(fields) != 2:
                continue
            for _ in range(2 * instance_count):
                _, at = self.uleb(at)
            method = 0
            for _ in range(direct_count):
                diff, at = self.uleb(at)
                _, at = self.uleb(at)  # access_flags
                code_at, at = self.uleb(at)
                method += diff
                if method >= self.methods_count:
                    raise ValueError("invalid DEX method index")
                name = self.uint(self.methods_at + 8 * method + 4)
                if code_at and self.string(name) == b"<clinit>":
                    yield code_at, fields

    def map_puts(self, code_at: int, map_fields: set[int]):
        """Track the operands of HashMap.put. Refuse branches and unrecognized instructions."""
        register_count, _, _, try_count, _, size = struct.unpack_from("<HHHHII", self.data, code_at)
        if try_count:
            return None
        code = struct.unpack_from(f"<{size}H", self.data, code_at + 16)
        registers = [None] * register_count
        fields = {}
        result = None
        at = 0
        while at < len(code):
            word = code[at]
            op, aa = word & 0xFF, word >> 8
            a, b = aa & 0xF, aa >> 4
            at += 1
            previous_result, result = result, None
            if word == 0:  # nop
                continue
            if word == 0x0E and at == len(code) and set(fields) == map_fields:
                return list(fields.values())
            if op in (0x01, 0x07):  # move, move-object
                registers[a] = registers[b]
            elif op in (0x02, 0x08):  # move/from16, move-object/from16
                registers[aa] = registers[code[at]]
                at += 1
            elif op in (0x03, 0x09):  # move/16, move-object/16
                registers[code[at]] = registers[code[at + 1]]
                at += 2
            elif op == 0x0C and previous_result is not None:  # move-result-object
                registers[aa] = previous_result
            elif op == 0x12:  # const/4
                registers[a] = _signed(b, 4)
            elif op in (0x13, 0x15):  # const/16, const/high16
                registers[aa] = _signed(code[at], 16) << (16 if op == 0x15 else 0)
                at += 1
            elif op == 0x14:  # const
                registers[aa] = _signed(code[at] | (code[at + 1] << 16), 32)
                at += 2
            elif op in (0x1A, 0x1B):  # const-string, const-string/jumbo
                index = code[at]
                at += 1
                if op == 0x1B:
                    index |= code[at] << 16
                    at += 1
                registers[aa] = self.string(index)
            elif op == 0x22 and self.type(code[at]) == _HASH_MAP:  # new-instance
                registers[aa] = []
                at += 1
            elif op == 0x62 and code[at] in fields:  # sget-object
                registers[aa] = fields[code[at]]
                at += 1
            elif op == 0x69 and code[at] in map_fields and isinstance(registers[aa], list):  # sput-object
                if code[at] in fields:
                    return None
                fields[code[at]] = registers[aa]
                at += 1
            elif op in (0x6E, 0x70, 0x71, 0x72, 0x74, 0x76, 0x77, 0x78):
                owner, name, returns, params = self.method(code[at])
                register_word = code[at + 1]
                at += 2
                if op >= 0x74:  # invoke-*/range
                    args = registers[register_word:register_word + aa]
                else:  # invoke-* with up to five explicitly encoded registers
                    indices = [(register_word >> shift) & 0xF for shift in (0, 4, 8, 12)] + [a]
                    args = [registers[index] for index in indices[:b]]
                if op in (0x71, 0x77):  # invoke-static
                    if (owner, name, returns, params) == (_INTEGER, b"valueOf", _INTEGER, (b"I",)):
                        if len(args) != 1 or not isinstance(args[0], int):
                            return None
                        result = _BoxedInt(args[0])
                    elif returns == _HASH_MAP:
                        # The optimizer can replace new HashMap(capacity) with a static factory call.
                        result = []
                    else:
                        return None
                elif op in (0x70, 0x76) and owner == _HASH_MAP and name == b"<init>":
                    if not args or not isinstance(args[0], list) or params not in ((), (b"I",)):
                        return None
                elif (owner in _MAP_TYPES and name == b"put" and returns == _OBJECT
                      and params == (_OBJECT, _OBJECT) and len(args) == 3 and isinstance(args[0], list)):
                    args[0].append((args[1], args[2]))
                else:
                    return None
            else:
                return None
        return None


def _entries(maps):
    """Normalize the two maps into forward and inverse entries, preserving duplicates for validation."""
    forward, inverse = [], []
    for puts in maps:
        in_order, reversed_order = [], []
        for key, value in puts:
            if isinstance(key, bytes) and isinstance(value, _BoxedInt):
                in_order.append((value.value, key))
            elif isinstance(key, _BoxedInt) and isinstance(value, bytes):
                reversed_order.append((key.value, value))
            else:
                return None
        if not puts or (in_order and reversed_order):
            return None
        forward.extend(in_order)
        inverse.extend(reversed_order)
    if forward and any(name.startswith(b"bk.action.") for _, name in forward):
        return forward, inverse
    return None


class SignInTables:
    def __init__(self):
        self.candidates = []

    def add(self, where: str, data: bytes) -> None:
        if not data.startswith(b"dex\n"):
            return
        try:
            dex = _Dex(data)
            for code, fields in dex.initializers():
                maps = dex.map_puts(code, fields)
                entries = _entries(maps) if maps else None
                if entries:
                    self.candidates.append((where, *entries))
        except (IndexError, struct.error, ValueError):
            raise TableError(f"Couldn't read DEX code in {where}. Pass an intact base APK or the whole bundle.") from None

    def choose(self) -> dict[int, str]:
        if not self.candidates:
            raise TableError("Couldn't find the sign-in function table. Pass the base APK or the whole bundle."
                             " If it is already included, try a different Meta AI version.")
        if len(self.candidates) != 1:
            raise TableError("Found more than one sign-in function table. Pass one Meta AI app version at a time.")
        where, forward, inverse = self.candidates[0]
        for entries in (forward, inverse):
            if len({id_ for id_, _ in entries}) != len(entries):
                raise TableError(f"The sign-in function table in {where} has duplicate IDs.")
            if len({name for _, name in entries}) != len(entries):
                raise TableError(f"The sign-in function table in {where} has duplicate names.")
        if len(forward) < MIN_FUNCTIONS:
            raise TableError(f"The sign-in function table in {where} has only {len(forward)} entries."
                             f" Expected at least {MIN_FUNCTIONS}. Try a different Meta AI version.")
        if inverse and set(forward) != set(inverse):
            raise TableError(f"The forward and reverse sign-in maps in {where} disagree. Try a different Meta AI version.")
        if any(id_ <= 0 or not _FUNCTION_NAME.fullmatch(name) for id_, name in forward):
            raise TableError(f"The sign-in function table in {where} has an invalid ID or name.")
        return {id_: name.decode("ascii") for id_, name in forward}


def table_text(entries: dict[int, str]) -> str:
    return "".join(f"{id_} {entries[id_]}\n" for id_ in sorted(entries))
