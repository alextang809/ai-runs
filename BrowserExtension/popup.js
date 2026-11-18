chrome.runtime.sendMessage({ event: "ping" }, (reply) => {
  const status = document.getElementById("status");
  if (reply && reply.ok) {
    status.textContent = "Connected to AI Runs.";
    status.className = "ok";
  } else {
    status.textContent = "Not connected to AI Runs.";
    status.className = "bad";
    document.getElementById("help").hidden = false;
  }
});
