import Base

# OS/private-filesystem boundary only. Job states, deadlines, events and polling
# policy live in Jobs.bend. All paths are relative to a checked private root.
def jfh_os(op: U32, id: String, name: String, text: String, argv: List<String>, limit: U32) -> IO(Result<&1, &1, U32 & String, String>):
  import "./host.c"

# The writer is exclusively created; readers get independent owned descriptors.
# Consume both with File.close, or pass writers to Process.run_logged.
def jfh_spool(id: String, name: String, writing: Bool) -> IO(Result<&1, &1, U32 & String, File>):
  import "./host.c"

def spool(id: String, name: String, writing: Bool) -> IO(File):
  IO.try(File, jfh_spool(id, name, writing))

def self() -> IO(String):
  IO.try(String, jfh_os(0, "", "", "", [], 0))

def create(max_jobs: U32) -> IO(String):
  IO.try(String, jfh_os(1, "", "", "", [], max_jobs))

# Missing files return empty text; unsafe/oversize files fail closed.
def read(id: String, name: String, limit: U32) -> IO(String):
  IO.try(String, jfh_os(2, id, name, "", [], limit))

def write(id: String, name: String, text: String) -> IO(Unit):
  do IO<Unit>:
    ignored : String <- IO.try(String, jfh_os(3, id, name, text, [], 1048576))
    return Unit{}

# Claim holds a private advisory lease until this process exits, then detaches.
def claim(id: String) -> IO(Unit):
  do IO<Unit>:
    ignored : String <- IO.try(String, jfh_os(4, id, "", "", [], 0))
    return Unit{}

def alive(id: String) -> IO(Bool):
  do IO<Bool>:
    text : String <- IO.try(String, jfh_os(5, id, "", "", [], 0))
    return String.eq(text, "1")

def spawn(argv: List<String>) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(6, "", "", "", argv, 0)
