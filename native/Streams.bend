import Base

# Incremental, replacement-decoding UTF-8. The decoder keeps at most one scalar
# across bounded spool reads. Output chunks are observations, not protocol lines.
type Decoder is Data:
  Decoder{need: U32, code: U32, minimum: U32, reversed: String}

def empty() -> Decoder:
  Decoder{0, 0, 0, ""}

# U+FFFD, emitted in place of each invalid or truncated sequence.
def replacement() -> U32:
  65533

# Any code point except UTF-16 surrogates (U+D800..U+DFFF).
def scalar(+code: U32) -> Bool:
  U32.is_le(code, 1114111) && Bool.not(U32.is_ge(code, 55296) && U32.is_le(code, 57343))

# A lead byte below 224 starts a 2-byte sequence, below 240 a 3-byte one, else 4 bytes.
# Each keeps its payload bits and the smallest scalar that sequence length may encode.
def sequence(+byte: U32, two: Bool, three: Bool, text: String) -> Decoder:
  match two three:
    case True{} _:
      Decoder{1, U32.mod(byte, 32), 128, text}
    case False{} True{}:
      Decoder{2, U32.mod(byte, 16), 2048, text}
    case False{} False{}:
      Decoder{3, U32.mod(byte, 8), 65536, text}

def lead(+b: U32, text: String, valid: Bool) -> Decoder:
  match valid:
    case False{}:
      Decoder{0, 0, 0, SCon{Chr{replacement()}, text}}
    case True{}:
      sequence(b, U32.is_lt(b, 224), U32.is_lt(b, 240), text)

def begin(+b: U32, text: String, ascii: Bool) -> Decoder:
  match ascii:
    case True{}:
      Decoder{0, 0, 0, SCon{Chr{b}, text}}
    case False{}:
      lead(b, text, U32.is_ge(b, 194) && U32.is_le(b, 244))

def complete(need: U32, +code: U32, +minimum: U32, text: String, last: Bool) -> Decoder:
  match last:
    case False{}:
      Decoder{need, code, minimum, text}
    case True{}:
      canonical = U32.is_ge(code, minimum) && scalar(code)
      Decoder{0, 0, 0, SCon{Chr{Bool.pick(U32, canonical, code, replacement())}, text}}

def continuation(
  +need: U32,
  code: U32,
  minimum: U32,
  text: String,
  +b: U32,
  valid: Bool,
) -> Decoder:
  match valid:
    case False{}:
      begin(b, SCon{Chr{replacement()}, text}, U32.is_lt(b, 128))
    case True{}:
      extended = U32.add(U32.mul(code, 64), U32.sub(b, 128))
      complete(U32.sub(need, 1), extended, minimum, text, U32.is_eq(need, 1))

def step(decoder: Decoder, +b: U32) -> Decoder:
  match decoder:
    case Decoder{0, code, minimum, text}:
      begin(b, text, U32.is_lt(b, 128))
    case Decoder{need, code, minimum, text}:
      continuation(need, code, minimum, text, b, U32.is_ge(b, 128) && U32.is_le(b, 191))

def feed(bytes: List<&2, U32>, decoder: Decoder) -> Decoder:
  match bytes:
    case Nil{}:
      decoder
    case Con{b, tail}:
      feed(tail, step(decoder, b))

def take(decoder: Decoder) -> Decoder & String:
  match decoder:
    case Decoder{need, code, minimum, text}:
      (Decoder{need, code, minimum, ""}, String.reverse(text))

def finish(decoder: Decoder) -> String:
  match decoder:
    case Decoder{0, code, minimum, text}:
      String.reverse(text)
    case Decoder{need, code, minimum, text}:
      String.reverse(SCon{Chr{replacement()}, text})
