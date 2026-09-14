const SCRIPT_URL = "https://guajun.github.io/ssh-command-scanner/scan.ps1";

const elements = {
  form: document.querySelector("#command-form"),
  username: document.querySelector("#username"),
  template: document.querySelector("#template"),
  startHost: document.querySelector("#start-host"),
  endHost: document.querySelector("#end-host"),
  timeout: document.querySelector("#timeout"),
  throttle: document.querySelector("#throttle"),
  command: document.querySelector("#generated-command"),
  copyButton: document.querySelector("#copy-button"),
  copyLabel: document.querySelector("#copy-label"),
  validation: document.querySelector("#validation-status"),
  targetCount: document.querySelector("#target-count"),
  previewList: document.querySelector("#target-preview-list"),
};

function quotePowerShell(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
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
  };
}

function getTemplateMatch(template) {
  const matches = [...template.matchAll(/(?<!\d)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.[xX](?![A-Za-z0-9])/g)];
  if (matches.length !== 1) return null;
  if (matches[0].slice(1).some((part) => Number(part) > 255)) return null;
  return matches[0];
}

function buildCommand(state) {
  const parameters = ["-CommandTemplate", quotePowerShell(state.template)];
  if (state.username) parameters.push("-UserName", quotePowerShell(state.username));
  parameters.push(
    "-StartHost",
    String(state.startHost),
    "-EndHost",
    String(state.endHost),
    "-Timeout",
    String(state.timeout),
    "-ThrottleLimit",
    String(state.throttle),
  );

  const loader = `[Text.Encoding]::UTF8.GetString((iwr -UseBasicParsing ${quotePowerShell(SCRIPT_URL)}).Content).TrimStart([char]0xFEFF)`;
  return `& ([scriptblock]::Create(${loader})) ${parameters.join(" ")}`;
}

function renderPreview(state, match) {
  const start = Math.min(state.startHost, state.endHost);
  const end = Math.max(state.startHost, state.endHost);
  const count = end - start + 1;
  const midpoint = Math.floor((start + end) / 2);
  const values = [...new Set([start, Math.min(start + 1, end), midpoint, end])];
  const prefix = match ? `${match[1]}.${match[2]}.${match[3]}` : "0.0.0";

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
  const isValid = Boolean(match) && state.startHost <= state.endHost && /^ssh(?:\.exe)?\s/i.test(state.template);

  elements.command.textContent = buildCommand(state);
  elements.copyButton.disabled = !isValid;
  elements.validation.textContent = isValid ? "模板有效" : "检查 ssh 开头、网段 .x 和地址范围";
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

render();
