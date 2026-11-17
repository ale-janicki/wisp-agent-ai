import json
from dataclasses import asdict, dataclass, field
from typing import Literal

OUTPUT_TAIL = 4000


@dataclass
class Detail:
    command: str
    exit: int
    output: str

    @staticmethod
    def capture(command: str, exit: int, stdout: str, stderr: str) -> "Detail":
        return Detail(command, exit, (stdout + stderr)[-OUTPUT_TAIL:])


@dataclass
class StepReport:
    step: str
    status: Literal["done", "skipped", "needs_user", "failed"]
    summary: str
    details: list[Detail] = field(default_factory=list)
    data: dict[str, str] = field(default_factory=dict)

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False)

    def exit_code(self) -> int:
        return 1 if self.status == "failed" else 0
