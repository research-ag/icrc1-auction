import { existsSync, unlinkSync, writeFileSync } from 'fs';
import path from 'path';
import { PocketIcServer } from '@dfinity/pic';
import { tmpdir } from 'os';

module.exports = async () => {
  const pid = process.ppid;
  const serverUrlFile = path.resolve(tmpdir(), 'pic_server_url.txt');
  const picServerPidFile = path.resolve(tmpdir(), 'pic_server.pid');
  const portFilePath = path.resolve(tmpdir(), `pocket_ic_${pid}.port`);

  if (existsSync(serverUrlFile)) {
    unlinkSync(serverUrlFile);
  }
  if (existsSync(picServerPidFile)) {
    try {
      unlinkSync(picServerPidFile);
    } catch {
    }
  }
  if (existsSync(portFilePath)) {
    try {
      unlinkSync(portFilePath);
    } catch {
    }
  }

  console.log('[jest.setup] Starting PocketIC server...');
  const picServer = await PocketIcServer.start({ showCanisterLogs: false, showRuntimeLogs: false });
  writeFileSync(serverUrlFile, picServer.getUrl(), 'utf-8');
  writeFileSync(picServerPidFile, (picServer as any).serverProcess.pid.toString(), 'utf-8');
  console.log(`[jest.setup] PocketIC server is running at ${picServer.getUrl()} (pid saved to ${picServerPidFile})`);
};
