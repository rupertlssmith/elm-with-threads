import esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["index.ts"],
  outfile: "build/index.js",
  bundle: true,
  platform: "node",
  target: ["node18"],
  sourcemap: true,
});
