#!/usr/bin/env node

/**
 * Cross-platform build and release script for GitHub releases.
 * - Builds the project using vite
 * - Zips the dist folder
 * - Creates a GitHub release with the artifact
 *
 * Prerequisites: gh CLI installed and authenticated (gh auth login)
 */

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// Get package version
const packageJson = require("./package.json");
const version = packageJson.version;
const zipFileName = `affff-admin-v${version}.zip`;

function run(command, options = {}) {
  console.log(`> ${command}`);
  try {
    execSync(command, { stdio: "inherit", ...options });
  } catch (error) {
    console.error(`Command failed: ${command}`);
    process.exit(1);
  }
}

function main() {
  console.log(`\n📦 Building and releasing v${version}...\n`);

  // Step 1: Check if wwwroot folder exists (built by vite build in package.json)
  const distPath = path.join(__dirname, "wwwroot");
  if (!fs.existsSync(distPath)) {
    console.error("Error: wwwroot folder not found. Run 'vite build' first.");
    process.exit(1);
  }

  // Step 2: Create zip file (cross-platform)
  console.log("\nStep 1: Creating zip archive...");
  const zipPath = path.join(__dirname, zipFileName);

  // Remove existing zip if present
  if (fs.existsSync(zipPath)) {
    fs.unlinkSync(zipPath);
  }

  // Use tar on all platforms (Node.js built-in via child process)
  // For Windows compatibility, use PowerShell's Compress-Archive or tar
  const isWindows = process.platform === "win32";

  if (isWindows) {
    // PowerShell Compress-Archive works on Windows 10+
    run(
      `powershell -Command "Compress-Archive -Path '${distPath}\\*' -DestinationPath '${zipPath}' -Force"`
    );
  } else {
    // macOS/Linux: use zip command
    run(`zip -r "${zipFileName}" .`, { cwd: distPath });
    // Move zip from dist to project root
    const srcZip = path.join(distPath, zipFileName);
    if (fs.existsSync(srcZip)) {
      fs.renameSync(srcZip, zipPath);
    }
  }

  if (!fs.existsSync(zipPath)) {
    console.error("Error: Failed to create zip file.");
    process.exit(1);
  }

  console.log(`Created: ${zipFileName}`);

  // Step 3: Create GitHub release
  console.log("\nStep 2: Creating GitHub release...");
  run(
    `gh release create v${version} "${zipFileName}" --title "v${version}" --generate-notes`
  );

  // Step 4: Cleanup zip file
  console.log("\nStep 3: Cleaning up...");
  if (fs.existsSync(zipPath)) {
    fs.unlinkSync(zipPath);
    console.log(`Removed: ${zipFileName}`);
  }

  console.log(`\n✅ Successfully released v${version}!\n`);
}

main();
