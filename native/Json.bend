import Base

# JSON output only. A strict JSON decoder remains a migration requirement.
def hex_digit(nibble: U32) -> Char:
  Char.from_u32((nibble + 48 : U32))

# 0-9 map to '0'-'9' (48 + n); 10-15 map to 'a'-'f' (87 + n).
def hex(nibble: U32, decimal: Bool) -> Char:
  match decimal:
    case True{}:
      hex_digit(nibble)
    case False{}:
      Char.from_u32((nibble + 87 : U32))

def hex_char(+nibble: U32) -> Char:
  hex(nibble, U32.is_lt(nibble, 10))

def control(+code: U32, small: Bool) -> String:
  match small:
    case True{}:
      high = hex_char((code / 16 : U32))
      low = hex_char((code % 16 : U32))
      "\\u00" ++ String.from_list([high, low])
    case False{}:
      SCon{Char.from_u32(code), SNil{}}

def escaped(c: Char) -> String:
  match c:
    case '"':
      "\\\""
    case '\\':
      "\\\\"
    case c:
      +code = Char.to_u32(c)
      control(code, U32.is_lt(code, 32))

def body(text: String) -> String:
  match text:
    case SNil{}:
      ""
    case SCon{head, tail}:
      escaped(head) ++ body(tail)

def quote(text: String) -> String:
  "\"" ++ body(text) ++ "\""

def boolean(value: Bool) -> String:
  match value:
    case False{}:
      "false"
    case True{}:
      "true"
