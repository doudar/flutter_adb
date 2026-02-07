// Copyright 2024 Pepe Tiebosch (byme.dev). All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

library flutter_adb;

import 'dart:convert';

import 'package:flutter_adb/adb_connection.dart';
import 'package:flutter_adb/adb_crypto.dart';
import 'package:flutter_adb/adb_stream.dart';
import 'package:flutter_adb/adb_sync.dart';

class Adb {
  /// Convenience method to open an ADB connection, open a shell and send a single command, then closing the connection.
  /// The function will return the sanitized output of the command.
  static Future<String> sendSingleCommand(
    String command, {
    String ip = '127.0.0.1',
    int port = 5555,
    AdbCrypto? crypto,
  }) async {
    AdbConnection connection = AdbConnection(ip, port, crypto ?? AdbCrypto());
    if (!await connection.connect()) {
      print('Failed to connect to $ip:$port');
      return '';
    }
    String finalCommand = '$command;exit\n';
    AdbStream stream = await connection.openShell();
    stream.writeString(finalCommand);
    String output = await stream.onPayload.fold('', (previous, element) => previous + utf8.decode(element)).timeout(
      const Duration(minutes: 1),
      onTimeout: () {
        print('Timeout closing the stream.');
        stream.close();
        return '';
      },
    );
    await connection.disconnect();
    // Sanitize output
    output = output.replaceAll('\r', '');
    output.endsWith('\n') ? output = output.substring(0, output.length - 1) : output;
    return output.split(finalCommand).last.trim();
  }

  static Future<bool> installApk(
    String apkPath, {
    String ip = '127.0.0.1',
    int port = 5555,
    AdbCrypto? crypto,
  }) async {
    AdbConnection connection = AdbConnection(ip, port, crypto ?? AdbCrypto());
    if (!await connection.connect()) {
      print('Failed to connect to $ip:$port');
      return false;
    }
    try {
      String remoteTemp = '/data/local/tmp/app_install_${DateTime.now().millisecondsSinceEpoch}.apk';
      
      AdbStream syncStream = await connection.open('sync:');
      AdbSync sync = AdbSync(syncStream);
      await sync.push(apkPath, remoteTemp);
      await sync.sendClose();
      
      String result = await _runCommand(connection, 'pm install -r "$remoteTemp"');
      // Cleanup
      await _runCommand(connection, 'rm "$remoteTemp"');
      
      return result.contains('Success');
    } catch (e) {
      print('Install error: $e');
      return false;
    } finally {
      await connection.disconnect();
    }
  }

  static Future<bool> uploadFile(
    String localPath,
    String remotePath, {
    String ip = '127.0.0.1',
    int port = 5555,
    AdbCrypto? crypto,
  }) async {
    AdbConnection connection = AdbConnection(ip, port, crypto ?? AdbCrypto());
    if (!await connection.connect()) {
      print('Failed to connect to $ip:$port');
      return false;
    }
    try {
      AdbStream stream = await connection.open('sync:');
      AdbSync sync = AdbSync(stream);
      await sync.push(localPath, remotePath);
      await sync.sendClose();
      return true;
    } catch (e) {
      print('Upload error: $e');
      return false;
    } finally {
      await connection.disconnect();
    }
  }

  static Future<bool> downloadFile(
    String remotePath,
    String localPath, {
    String ip = '127.0.0.1',
    int port = 5555,
    AdbCrypto? crypto,
  }) async {
    AdbConnection connection = AdbConnection(ip, port, crypto ?? AdbCrypto());
    if (!await connection.connect()) {
      print('Failed to connect to $ip:$port');
      return false;
    }
    try {
      AdbStream stream = await connection.open('sync:');
      AdbSync sync = AdbSync(stream);
      await sync.pull(remotePath, localPath);
      await sync.sendClose();
      return true;
    } catch (e) {
      print('Download error: $e');
      return false;
    } finally {
      await connection.disconnect();
    }
  }

  static Future<String> _runCommand(AdbConnection connection, String command) async {
    String finalCommand = '$command;exit\n';
    AdbStream stream = await connection.openShell();
    stream.writeString(finalCommand);
    String output = await stream.onPayload.fold('', (previous, element) => previous + utf8.decode(element)).timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        stream.close();
        return '';
      },
    );
    
    // Sanitize output
    output = output.replaceAll('\r', '');
    output.endsWith('\n') ? output = output.substring(0, output.length - 1) : output;
    
    // Attempt to remove the echoed command from output
    // The exact behavior depends on the shell, but splitting by command is a common heuristic
    if (output.contains(finalCommand.trim())) {
         List<String> parts = output.split(finalCommand.trim());
         if (parts.length > 1) {
           return parts.last.trim();
         }
    }
    
    return output.trim();
  }

