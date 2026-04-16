// Node.js entrypoint for the Kafka orders example

// @ts-ignore - Elm compiled output
const { Elm } = require("./build/elm.js");

function main() {
  const app = Elm.Main.init({ flags: null });

  if (app.ports && app.ports.logPort) {
    app.ports.logPort.subscribe((msg: string) => {
      console.log(msg);
    });
  }

  if (app.ports && app.ports.exitPort) {
    app.ports.exitPort.subscribe(() => {
      console.log("Elm requested exit.");
      process.exit(0);
    });
  }

  setTimeout(() => {
    console.log("--- Shutting down after 3s ---");
    process.exit(0);
  }, 3000);
}

main();
