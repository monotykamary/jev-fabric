import Base

# JSON output only. A strict JSON decoder remains a migration requirement.
def hex_digit(v: U32) -> Char:
  Char.from_u32((v + 48 : U32))

def hex(v: U32, decimal: Bool) -> Char:
  match decimal:
    case True{}:
      hex_digit(v)
    case False{}:
      Char.from_u32((v + 87 : U32))

def hex_char(+v: U32) -> Char:
  hex(v, U32.is_lt(v, 10))

def control(+code: U32, small: Bool) -> String:
  match small:
    case True{}:
      "\\u00" ++ String.from_list([hex_char((code / 16 : U32)), hex_char((code % 16 : U32))])
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
