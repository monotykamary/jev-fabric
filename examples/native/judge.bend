import Base
import ../../native/Jev.bend as Jev
import ../../native/Codec.bend as Codec

def show(returned: Jev.Returned) -> IO(Unit):
  (client, result) = returned
  do IO<Unit>:
    value : Codec.Value <- IO.pass(Codec.Value, result)
    text : String <- IO.pass(String, Codec.encode(value))
    IO.print(text)

# Opt-in: sends only synthetic text. Credentials resolve privately from env/argv.
def main() -> IO(Unit):
  do IO<Unit>:
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(1, 10000))
    result : Jev.Returned <- Jev.evaluate(client, "{\"state\":\"Synthetic build: 12 tests passed.\",\"questions\":{\"healthy\":{\"type\":\"noul\",\"instructions\":\"Do the observed tests appear healthy?\"}}}")
    show(result)
