// Limen proof-of-work challenge: page script.
//
// Reads the challenge from data attributes, spreads the nonce search over
// Web Workers, and submits the first solution found. No inline code, no
// third-party assets: the page works under a strict Content-Security-Policy.
(function () {
  "use strict";

  var root = document.getElementById("limen-challenge");
  if (!root) return;

  var form = document.getElementById("limen-form");
  var status = document.getElementById("limen-status");
  var token = root.getAttribute("data-token");
  var difficulty = Number(root.getAttribute("data-difficulty"));
  var workerUrl = root.getAttribute("data-worker");

  function fail(message) {
    status.textContent = message;
    root.setAttribute("data-state", "failed");
  }

  if (typeof Worker === "undefined") {
    fail("Your browser cannot run the check. Please use a recent browser.");
    return;
  }

  var count = Math.max(1, Math.min(navigator.hardwareConcurrency || 2, 8));
  var workers = [];
  var solved = false;

  function stop() {
    for (var i = 0; i < workers.length; i++) workers[i].terminate();
  }

  for (var i = 0; i < count; i++) {
    var worker = new Worker(workerUrl);

    worker.onmessage = function (event) {
      if (solved) return;
      solved = true;
      stop();
      form.elements.nonce.value = event.data.nonce;
      root.setAttribute("data-state", "solved");
      status.textContent = "Done, taking you there…";
      form.submit();
    };

    worker.onerror = function () {
      if (solved) return;
      stop();
      fail("The check could not run in this browser.");
    };

    worker.postMessage({ token: token, difficulty: difficulty, start: i, step: count });
    workers.push(worker);
  }

  root.setAttribute("data-state", "solving");
})();
