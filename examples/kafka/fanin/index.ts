// Node.js entrypoint for the Kafka fan-in example

// @ts-ignore - Elm compiled output
const { Elm } = require("./build/elm.js");

function main() {
  const app = Elm.Main.init({ flags: null });

  if (app.ports && app.ports.logPort) {
    app.ports.logPort.subscribe((msg: string) => {
      console.log(msg);
    });
  }

  // Wire the P2P port-bounce: echo notifyP2PSend back through onP2PSend
  if (app.ports && app.ports.notifyP2PSend && app.ports.onP2PSend) {
    app.ports.notifyP2PSend.subscribe(
      (data: { subjectId: number; messageId: number }) => {
        app.ports.onP2PSend.send(data);
      }
    );
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
