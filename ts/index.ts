// Node.js entrypoint for elm-actor-kafka

// @ts-ignore - Elm compiled output
const { Elm } = require("../build/elm.js");

function main() {
  const app = Elm.Main.init({ flags: null });

  // Wire the log port
  if (app.ports && app.ports.logPort) {
    app.ports.logPort.subscribe((msg: string) => {
      console.log(msg);
    });
  }

  // Wire the exit port
  if (app.ports && app.ports.exitPort) {
    app.ports.exitPort.subscribe(() => {
      console.log("Elm requested exit.");
      process.exit(0);
    });
  }

  // Keep process alive for subscriptions (Time.every)
  // Exit after 3 seconds to demonstrate it runs
  setTimeout(() => {
    console.log("--- Shutting down after 3s ---");
    process.exit(0);
  }, 3000);
}

main();
