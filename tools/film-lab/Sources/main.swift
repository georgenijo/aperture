import CoreImage
import Foundation

// film-lab-renderer: the Swift half of Local Film Lab. It links the app's own
// processing sources and is driven by server.py over NDJSON (`serve`), or run
// directly for its self-tests and golden comparison.

func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      """
      usage:
        film-lab-renderer serve --root DIR --controls PATH [--test-hooks] [--max-pixels N]
        film-lab-renderer selftest --controls PATH --fixtures DIR
        film-lab-renderer compare-golden --controls PATH --fixtures DIR [--out DIR]
        film-lab-renderer hello --controls PATH

      """.utf8))
  exit(64)
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("film-lab-renderer: \(message)\n".utf8))
  exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

var options: [String: String] = [:]
var flags: Set<String> = []
while let argument = arguments.first {
  arguments.removeFirst()
  switch argument {
  case "--test-hooks":
    flags.insert(argument)
  case "--root", "--controls", "--fixtures", "--max-pixels", "--out":
    guard let value = arguments.first else { usage() }
    arguments.removeFirst()
    options[argument] = value
  default:
    usage()
  }
}

guard let controlsPath = options["--controls"] else { usage() }
let schema: ControlSchema
do {
  schema = try ControlSchema.load(from: URL(fileURLWithPath: controlsPath))
} catch {
  fail("\(error)")
}

// The schema and the handler table must agree before anything runs.
let handlerIDs = LabRecipeBuilder.handlers.map(\.id)
guard Set(handlerIDs) == Set(schema.controls.map(\.id)), Set(handlerIDs).count == handlerIDs.count
else {
  fail("controls.json and the Swift handlers disagree: \(handlerIDs)")
}
guard schema.baseRecipeID == LabRecipeBuilder.baseRecipe.id.rawValue,
  schema.baseRecipeVersion == LabRecipeBuilder.baseRecipe.version
else {
  fail("controls.json targets \(schema.baseRecipeID) v\(schema.baseRecipeVersion), but this build ships \(LabRecipeBuilder.baseRecipe.id.rawValue) v\(LabRecipeBuilder.baseRecipe.version).")
}

switch command {
case "serve":
  guard let rootPath = options["--root"] else { usage() }
  let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { fail("--root must be an existing directory") }
  let maximumPixels = options["--max-pixels"].flatMap(Int.init) ?? LabImaging.defaultMaximumPixels
  guard maximumPixels > 0 else { usage() }
  // A closed pipe must end the worker rather than kill it mid-write.
  signal(SIGPIPE, SIG_IGN)
  LabWorker(
    schema: schema, root: root, testHooks: flags.contains("--test-hooks"),
    maximumPixels: maximumPixels
  ).run()

case "hello":
  let worker = LabWorker(
    schema: schema, root: URL(fileURLWithPath: "/nonexistent"), testHooks: false,
    maximumPixels: LabImaging.defaultMaximumPixels)
  FileHandle.standardOutput.write(worker.handle(line: #"{"id":0,"op":"hello"}"#))

case "selftest":
  guard let fixtures = options["--fixtures"] else { usage() }
  var tests = LabSelfTests(schema: schema, fixtures: URL(fileURLWithPath: fixtures))
  exit(tests.run() ? 0 : 1)

case "compare-golden":
  guard let fixtures = options["--fixtures"] else { usage() }
  exit(
    LabGoldenComparison.run(
      fixtures: URL(fileURLWithPath: fixtures),
      output: options["--out"].map { URL(fileURLWithPath: $0) }) ? 0 : 1)

default:
  usage()
}
