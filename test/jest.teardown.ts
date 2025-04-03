import path from 'path';
import { existsSync, readFileSync, unlinkSync } from 'fs';
import { tmpdir } from 'os';
import * as process from 'node:process';

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
      let pid = +readFileSync(picServerPidFile);
      process.kill(pid);
    } catch (err) {
      // pass
    }
    unlinkSync(picServerPidFile);
  }
  if (existsSync(portFilePath)) {
    unlinkSync(portFilePath);
  }
};
