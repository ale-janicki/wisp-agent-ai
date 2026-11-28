import { describe, expect, it } from "vitest";
import { abbreviateDirectory, directoryFromReport, directoryLabel } from "./directory";
import { parseGitStatus } from "./git";

const porcelain = [
  "# branch.oid 1234567890abcdef",
  "# branch.head feat/x",
  "1 .M N... 100644 100644 100644 aaa bbb src/a.ts",
  "2 R. N... 100644 100644 100644 aaa bbb R100 new.ts\told.ts",
  "u UU N... 100644 100644 100644 100644 a b c conflict.ts",
  "? untracked.txt",
  "! ignored.txt",
].join("\n");

describe("parseGitStatus", () => {
  it("reads the branch, changed files (tracked, renamed, unmerged, untracked) and the line counts", () => {
    expect(parseGitStatus(porcelain, " 3 files changed, 10 insertions(+), 2 deletions(-)\n")).toEqual({
      branch: "feat/x",
      changedFiles: 4,
      insertions: 10,
      deletions: 2,
    });
  });

  it("reads a lone insertions or deletions count", () => {
    expect(parseGitStatus("# branch.head main\n", " 1 file changed, 1 deletion(-)")).toMatchObject({ insertions: 0, deletions: 1 });
  });

  it("a detached head shows the first 7 of the commit; none at all gives null", () => {
    expect(parseGitStatus("# branch.oid abcdef0123456\n# branch.head (detached)\n", "")!.branch).toBe("abcdef0");
    expect(parseGitStatus("# branch.oid (initial)\n# branch.head (detached)\n", "")).toBeNull();
    expect(parseGitStatus("not git", "")).toBeNull();
  });
});

describe("directoryFromReport", () => {
  it("reads a file URL of a drive, with escapes", () => {
    expect(directoryFromReport("file:///C:/Users/dev/My%20Dir")).toBe("C:\\Users\\dev\\My Dir");
  });
  it("reads a UNC file URL and a plain absolute Windows path", () => {
    expect(directoryFromReport("file://srv/share/x")).toBe("\\\\srv\\share\\x");
    expect(directoryFromReport("D:\\work")).toBe("D:\\work");
  });
  it("refuses anything else", () => {
    expect(directoryFromReport("relative/dir")).toBeNull();
    expect(directoryFromReport("")).toBeNull();
    expect(directoryFromReport(null)).toBeNull();
    expect(directoryFromReport("http://x/y")).toBeNull();
  });
});

describe("directory labels", () => {
  it("shortens the home folder to ~, case-insensitively", () => {
    expect(abbreviateDirectory("C:\\Users\\dev", "c:\\users\\dev")).toBe("~");
    expect(abbreviateDirectory("C:\\Users\\dev\\x\\y", "C:\\Users\\dev")).toBe("~\\x\\y");
    expect(abbreviateDirectory("D:\\x", "C:\\Users\\dev")).toBe("D:\\x");
  });
  it("folds a deep path to root, an ellipsis and the last folder", () => {
    expect(directoryLabel("C:\\Users\\dev\\x\\y\\z", "C:\\Users\\dev")).toBe("~\\…\\z");
    expect(directoryLabel("D:\\a\\b\\c", null)).toBe("D:\\…\\c");
    expect(directoryLabel("D:\\a", null)).toBe("D:\\a");
  });
});
