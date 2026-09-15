const SCRIPT_URL = "https://guajun.github.io/ssh-command-scanner/scan.ps1";
const BASH_SCRIPT_URL = "https://guajun.github.io/ssh-command-scanner/scan.sh";
const DEFAULT_HOST_LIMIT = 1024;
const ABSOLUTE_HOST_LIMIT = 65536;

const elements = {
  form: document.querySelector("#command-form"),
  username: document.querySelector("#username"),
  target: document.querySelector("#target"),
  port: document.querySelector("#port"),
  identity: document.querySelector("#identity"),
  jumpHost: document.querySelector("#jump-host"),
  sshConfig: document.querySelector("#ssh-config"),
  timeout: document.querySelector("#timeout"),
  concurrency: document.querySelector("#concurrency"),
  textOutput: document.querySelector("#text-output"),
  allAddresses: document.querySelector("#all-addresses"),
  allowLargeRange: document.querySelector("#allow-large-range"),
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

function numberToIPv4(value) {
  return [
    Math.floor(value / 16777216) % 256,
    Math.floor(value / 65536) % 256,
    Math.floor(value / 256) % 256,
    value % 256,
  ].join(".");
}

function parseIPv4Cidr(value, includeAllAddresses) {
  const match = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d|[12]\d|3[0-2])$/);
  if (!match) return null;

  const octets = match.slice(1, 5).map(Number);
  if (octets.some((octet) => octet > 255)) return null;

  const prefixLength = Number(match[5]);
  const addressValue = octets.reduce((total, octet) => total * 256 + octet, 0);
  const blockSize = 2 ** (32 - prefixLength);
  const networkValue = Math.floor(addressValue / blockSize) * blockSize;
  const broadcastValue = networkValue + blockSize - 1;
  const skipBoundaries = !includeAllAddresses && prefixLength <= 30;
  const firstValue = skipBoundaries ? networkValue + 1 : networkValue;
  const lastValue = skipBoundaries ? broadcastValue - 1 : broadcastValue;

  return {
    canonical: `${numberToIPv4(networkValue)}/${prefixLength}`,
    count: lastValue - firstValue + 1,
    firstValue,
    lastValue,
  };
}

function readState() {
  return {
    username: elements.username.value.trim(),
    target: elements.target.value.trim(),
    port: clampInteger(elements.port.value, 1, 65535, 22),
    identity: elements.identity.value.trim(),
    jumpHost: elements.jumpHost.value.trim(),
    sshConfig: elements.sshConfig.value.trim(),
    timeout: clampInteger(elements.timeout.value, 1, 60, 3),
    concurrency: clampInteger(elements.concurrency.value, 1, 128, 32),
    textOutput: elements.textOutput.value.trim(),
    allAddresses: elements.allAddresses.checked,
    allowLargeRange: elements.allowLargeRange.checked,
  };
}

function buildCommand(state) {
  if (selectedMode === "bash") {
    const parameters = [
      "--user", quoteBash(state.username),
      "--target", quoteBash(state.target),
      "--port", String(state.port),
      "--timeout", String(state.timeout),
      "--concurrency", String(state.concurrency),
    ];
    if (state.identity) parameters.push("--identity", quoteBash(state.identity));
    if (state.jumpHost) parameters.push("--jump-host", quoteBash(state.jumpHost));
    if (state.sshConfig) parameters.push("--ssh-config", quoteBash(state.sshConfig));
    if (state.textOutput) parameters.push("--text-output", quoteBash(state.textOutput));
    if (state.allAddresses) parameters.push("--all-addresses");
    if (state.allowLargeRange) parameters.push("--allow-large-range");
    return `bash <(curl -fsSL ${quoteBash(BASH_SCRIPT_URL)}) ${parameters.join(" ")}`;
  }

  const parameters = [
    "-UserName", quotePowerShell(state.username),
    "-Target", quotePowerShell(state.target),
    "-Port", String(state.port),
    "-Timeout", String(state.timeout),
    "-Concurrency", String(state.concurrency),
  ];
  if (state.identity) parameters.push("-Identity", quotePowerShell(state.identity));
  if (state.jumpHost) parameters.push("-JumpHost", quotePowerShell(state.jumpHost));
  if (state.sshConfig) parameters.push("-SshConfig", quotePowerShell(state.sshConfig));
  if (state.textOutput) parameters.push("-TextOutputPath", quotePowerShell(state.textOutput));
  if (state.allAddresses) parameters.push("-AllAddresses");
  if (state.allowLargeRange) parameters.push("-AllowLargeRange");

  const loader = `[Text.Encoding]::UTF8.GetString((iwr -UseBasicParsing ${quotePowerShell(SCRIPT_URL)}).Content).TrimStart([char]0xFEFF)`;
  return `& ([scriptblock]::Create(${loader})) ${parameters.join(" ")}`;
}

function renderPreview(resolvedTarget) {
  if (!resolvedTarget) {
    elements.targetCount.textContent = "未配置";
    elements.previewList.classList.add("empty");
    const item = document.createElement("li");
    item.textContent = "—";
    elements.previewList.replaceChildren(item);
    return;
  }

  const midpoint = Math.floor((resolvedTarget.firstValue + resolvedTarget.lastValue) / 2);
  const values = [...new Set([
    resolvedTarget.firstValue,
    Math.min(resolvedTarget.firstValue + 1, resolvedTarget.lastValue),
    midpoint,
    resolvedTarget.lastValue,
  ])];

  elements.previewList.classList.remove("empty");
  elements.targetCount.textContent = `${resolvedTarget.count} · ${resolvedTarget.canonical}`;
  elements.previewList.replaceChildren(
    ...values.map((value) => {
      const item = document.createElement("li");
      item.textContent = numberToIPv4(value);
      return item;
    }),
  );
}

function validate(state, resolvedTarget) {
  if (!state.username || !state.target) return "请填写用户名和目标 CIDR";
  if (/\s|[\x00-\x1f\x7f]/.test(state.username)) return "用户名不能包含空白或控制字符";
  if (!resolvedTarget) return "目标必须是有效的 IPv4 CIDR";
  if (/\s|[\x00-\x1f\x7f]/.test(state.jumpHost)) return "跳板机不能包含空白或控制字符";
  if ([state.identity, state.sshConfig, state.textOutput].some((value) => /[\x00-\x1f\x7f]/.test(value))) return "路径不能包含控制字符";
  if (state.textOutput) {
    const fileName = state.textOutput.split(/[\\/]/).pop();
    if (fileName.includes(".") && !fileName.toLowerCase().endsWith(".txt")) return "表格文件必须使用 .txt 扩展名";
  }
  if (resolvedTarget.count > ABSOLUTE_HOST_LIMIT) return `目标超过绝对上限 ${ABSOLUTE_HOST_LIMIT}`;
  if (resolvedTarget.count > DEFAULT_HOST_LIMIT && !state.allowLargeRange) return `目标超过默认上限 ${DEFAULT_HOST_LIMIT}`;
  return "参数有效";
}

function render() {
  const state = readState();
  const resolvedTarget = parseIPv4Cidr(state.target, state.allAddresses);
  const validationMessage = validate(state, resolvedTarget);
  const isValid = validationMessage === "参数有效";

  elements.command.textContent = buildCommand(state);
  elements.copyButton.disabled = !isValid;
  elements.validation.textContent = validationMessage;
  elements.validation.classList.toggle("invalid", !isValid);
  renderPreview(resolvedTarget);
}

async function copyCommand() {
  await navigator.clipboard.writeText(elements.command.textContent);
  elements.copyLabel.textContent = "已复制";
  window.setTimeout(() => {
    elements.copyLabel.textContent = "复制命令";
  }, 1600);
}

elements.form.addEventListener("input", render);
elements.form.addEventListener("change", render);
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
