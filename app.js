const SCRIPT_URL = "https://guajun.github.io/ssh-command-scanner/scan.ps1";
const BASH_SCRIPT_URL = "https://guajun.github.io/ssh-command-scanner/scan.sh";

const elements = {
  form: document.querySelector("#command-form"),
  username: document.querySelector("#username"),
  template: document.querySelector("#template"),
  startHost: document.querySelector("#start-host"),
  endHost: document.querySelector("#end-host"),
  timeout: document.querySelector("#timeout"),
  throttle: document.querySelector("#throttle"),
  textOutput: document.querySelector("#text-output"),
  modeButtons: [...document.querySelectorAll("[data-mode]")],
  command: document.querySelector("#generated-command"),
  copyButton: document.querySelector("#copy-button"),
  copyLabel: document.querySelector("#copy-label"),
  validation: document.querySelector("#validation-status"),
  targetCount: document.querySelector("#target-count"),
  previewList: document.querySelector("#target-preview-list"),
};

let selectedMode = "powershell";

function quotePowerShell(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function quoteBash(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function clampInteger(value, minimum, maximum, fallback) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}

function readState() {
  return {
    username: elements.username.value.trim(),
    template: elements.template.value.trim(),
    startHost: clampInteger(elements.startHost.value, 0, 255, 1),
    endHost: clampInteger(elements.endHost.value, 0, 255, 254),
    timeout: clampInteger(elements.timeout.value, 1, 60, 3),
    throttle: clampInteger(elements.throttle.value, 1, 128, 32),
    textOutput: elements.textOutput.value.trim(),
  };
}

function getTemplateMatch(template) {
  const matches = [...template.matchAll(/(?<!\d)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.[xX](?![A-Za-z0-9])/g)];
  if (matches.length !== 1) return null;
  if (matches[0].slice(1).some((part) => Number(part) > 255)) return null;
  return matches[0];
}

function buildCommand(state) {
  if (selectedMode === "bash") {
    const parameters = [];
    if (state.template) parameters.push("--command-template", quoteBash(state.template));
    if (state.username) parameters.push("--user", quoteBash(state.username));
    parameters.push(
      "--start-host",
      String(state.startHost),
      "--end-host",
      String(state.endHost),
      "--timeout",
      String(state.timeout),
      "--throttle-limit",
      String(state.throttle),
    );
    if (state.textOutput) parameters.push("--text-output-path", quoteBash(state.textOutput));
    return `bash <(curl -fsSL ${quoteBash(BASH_SCRIPT_URL)}) ${parameters.join(" ")}`;
  }

  const parameters = [];
  if (state.template) parameters.push("-CommandTemplate", quotePowerShell(state.template));
  if (state.username) parameters.push("-UserName", quotePowerShell(state.username));
  parameters.push(
    "-StartHost", String(state.startHost),
    "-EndHost", String(state.endHost),
    "-Timeout", String(state.timeout),
    "-ThrottleLimit", String(state.throttle),
  );
  if (state.textOutput) parameters.push("-TextOutputPath", quotePowerShell(state.textOutput));

  const loader = `[Text.Encoding]::UTF8.GetString((iwr -UseBasicParsing ${quotePowerShell(SCRIPT_URL)}).Content).TrimStart([char]0xFEFF)`;
  return `& ([scriptblock]::Create(${loader})) ${parameters.join(" ")}`;
}

function renderPreview(state, match) {
  if (!match) {
    elements.targetCount.textContent = "未配置";
    elements.previewList.classList.add("empty");
    const item = document.createElement("li");
    item.textContent = "—";
    elements.previewList.replaceChildren(item);
    return;
  }

  const start = Math.min(state.startHost, state.endHost);
  const end = Math.max(state.startHost, state.endHost);
  const count = end - start + 1;
  const midpoint = Math.floor((start + end) / 2);
  const values = [...new Set([start, Math.min(start + 1, end), midpoint, end])];
  const prefix = `${match[1]}.${match[2]}.${match[3]}`;

  elements.previewList.classList.remove("empty");
  elements.targetCount.textContent = `${count} host${count === 1 ? "" : "s"}`;
  elements.previewList.replaceChildren(
    ...values.map((host) => {
      const item = document.createElement("li");
      item.textContent = `${prefix}.${host}`;
      return item;
    }),
  );
}

function render() {
  const state = readState();
  const match = getTemplateMatch(state.template);
  const isInteractive = state.template === "";
  const isValid = state.startHost <= state.endHost && (isInteractive || (Boolean(match) && /^ssh(?:\.exe)?\s/i.test(state.template)));

  elements.command.textContent = buildCommand(state);
  elements.copyButton.disabled = !isValid;
  elements.validation.textContent = isInteractive ? "运行时询问" : isValid ? "模板有效" : "检查 ssh 开头、网段 .x 和地址范围";
  elements.validation.classList.toggle("invalid", !isValid);
  renderPreview(state, match);
}

async function copyCommand() {
  await navigator.clipboard.writeText(elements.command.textContent);
  elements.copyLabel.textContent = "已复制";
  window.setTimeout(() => {
    elements.copyLabel.textContent = "复制命令";
  }, 1600);
}

elements.form.addEventListener("input", render);
elements.form.addEventListener("submit", (event) => event.preventDefault());
elements.copyButton.addEventListener("click", () => {
  copyCommand().catch(() => {
    elements.copyLabel.textContent = "复制失败";
  });
});
elements.modeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    selectedMode = button.dataset.mode;
    elements.modeButtons.forEach((candidate) => {
      candidate.setAttribute("aria-selected", String(candidate === button));
    });
    render();
  });
});

render();
