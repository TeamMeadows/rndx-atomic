---@type PackageMeta
return {
  id = "dev.srlion.rndx",
  title = "RNDX",
  description = "RNDX is a lightweight and efficient library designed to make drawing rounded shapes simple, fast, and visually stunning.",
  kind = "library",
  version = "1.0.0+commit.012d33b",
  files = {
    dir = "common",
    client = {"client"}
  },
  dependencies = {
    client = {
      atomic = "^1.0.0-rc.4"
    }
  }
}