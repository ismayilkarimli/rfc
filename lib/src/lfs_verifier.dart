// Copyright 2026 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io' show Platform, Process;

import 'package:path/path.dart' as p;

import 'github_annotation.dart';
import 'process_logger.dart';
import 'process_runner.dart';

String _decodeStdout(dynamic stdout) => switch (stdout) {
  null => '',
  List<int> bytes => utf8.decode(bytes, allowMalformed: true),
  String str => str,
  _ => '$stdout',
};

List<String> _parseNulTerminated(String output) =>
    output.split('\u0000').where((s) => s.isNotEmpty).toList();

/// Detects GitHub Actions pull request environments and returns base branch, or null.
String? resolveEnvironmentBaseBranch([Map<String, String>? env]) {
  final environment = env ?? Platform.environment;
  final eventName =
      environment['GITHUB_EVENT_NAME'] ?? environment['EVENT_NAME'];
  final envBase = environment['GITHUB_BASE_REF'] ?? environment['BASE_REF'];

  return switch ((eventName, envBase)) {
    ('pull_request', final base?) when base.startsWith('origin/') => base,
    ('pull_request', final base?) when base.isNotEmpty => 'origin/$base',
    _ => null,
  };
}

/// An issue detected during Git LFS verification.
class LfsIssue implements GithubAnnotatable {
  /// The file path associated with this issue, or empty if repository-level.
  final String filePath;

  /// The error description.
  final String message;

  const LfsIssue({required this.filePath, required this.message});

  @override
  String toGithubAnnotation() => switch (filePath) {
    '' => '::error::${message.toGithubWorkflowValue()}',
    _ => message.toGithubAnnotation(filePath: filePath),
  };

  @override
  String toString() => switch (filePath) {
    '' => '[ERROR] $message',
    _ => '[ERROR] $filePath: $message',
  };
}

/// The result of a Git LFS verification run.
typedef LfsVerificationResult = ({bool isSuccess, List<LfsIssue> issues});

/// Verifier that enforces Git LFS pointer consistency for repository trees
/// using `git lfs fsck --pointers`.
///
/// Rather than maintaining a duplicate whitelist of file extensions in Dart,
/// this tool treats `.gitattributes` as the single source of truth:
/// Git LFS natively parses `.gitattributes` and verifies that all matching files
/// are stored as valid LFS pointers in the Git object database.
class LfsVerifier {
  /// Matches diagnostic error lines output by `git lfs fsck --pointers`.
  ///
  /// Matches lines starting with `pointer:` and containing `unexpectedGitObject:`,
  /// capturing the quoted file path in group 1 and any trailing diagnostic detail in group 2:
  /// ```text
  /// pointer: unexpectedGitObject: "<path>" (treeish <sha>) should have been a pointer but was not
  /// ```
  static final _unexpectedGitObjectRegex = RegExp(
    r'^pointer:.*unexpectedGitObject:.*"([^"]+)"(.*)',
  );

  /// Parses `git lfs fsck --pointers` stdout/stderr into structured [LfsIssue]s.
  ///
  /// Extracts the file path from group 1 and assigns the diagnostic detail from group 2
  /// as the issue message.
  ///
  /// ### Git LFS fsck Output Behavior:
  /// - **Success** (exit code 0): Emits `Git LFS fsck OK`.
  /// - **Failure** (exit code 1): Emits one or more lines matching
  ///   `pointer: unexpectedGitObject: "<path>" (treeish <sha>) should have been a pointer but was not`
  ///   when a file tracked in `.gitattributes` was committed as a raw binary blob instead of an LFS pointer.
  ///
  /// ### Why Structured Parsing:
  /// 1. **GitHub PR Annotations**: Extracting `filePath` allows formatting errors as
  ///    `::error file=<path>::...`, placing inline annotations directly on the PR diff.
  /// 2. **Pull Request Isolation**: Enables filtering against `allowedFiles` (the files modified
  ///    in the PR), ensuring legacy issues in the base branch do not block unrelated PR authors.
  /// 3. **Defense-in-Depth Fallback**: If Git LFS exits non-zero but the output cannot be parsed
  ///    by this regex (e.g. format change or general Git error), the caller falls back to emitting
  ///    a repository-level issue with the raw output, ensuring errors are never swallowed.
  static List<LfsIssue> parseFsckOutput(String output) {
    final issues = <LfsIssue>[];
    final seen = <String>{};
    for (final line in LineSplitter.split(output)) {
      final match = _unexpectedGitObjectRegex.firstMatch(line.trim());
      if (match != null) {
        final rawPath = match.group(1)!;
        final detail = match.group(2)?.trim() ?? '';
        final normalized = p.posix.normalize(rawPath.replaceAll(r'\', '/'));
        if (seen.add(normalized)) {
          final message = detail.isNotEmpty
              ? detail
              : 'should have been a pointer but was not';
          issues.add(LfsIssue(filePath: normalized, message: message));
        }
      }
    }
    return issues;
  }

  final ProcessRunner processRunner;
  final void Function(String message)? onLog;
  final void Function(String message)? onError;

  LfsVerifier({this.processRunner = Process.run, this.onLog, this.onError});

  /// Checks whether Git LFS is installed and accessible in the environment.
  Future<bool> isLfsInstalled() async {
    try {
      final result = await processRunner('git', ['lfs', 'version']);
      return result.exitCode == 0;
    } catch (e) {
      logProcessError(e, command: 'git lfs version', onError: onError);
      return false;
    }
  }

  /// Resolves the base commit or branch ref to compare against.
  Future<String?> resolveBaseTarget(String baseBranch) async {
    // A set literal collapses the overlap between the explicit candidates and
    // the `main` fallbacks (e.g. `origin/main` would otherwise be probed twice).
    final candidateRefs = {
      baseBranch,
      if (!baseBranch.startsWith('origin/')) 'origin/$baseBranch',
      if (baseBranch.startsWith('origin/'))
        baseBranch.substring('origin/'.length),
      if (baseBranch == 'main' || baseBranch == 'origin/main') ...[
        'origin/main',
        'main',
      ],
    };

    for (final candidate in candidateRefs) {
      final res = await processRunner('git', [
        'rev-parse',
        '--verify',
        candidate,
      ]);
      if (res.exitCode == 0) {
        return candidate;
      }
    }
    return null;
  }

  /// Determines the merge base commit between [baseTarget] and `HEAD`.
  Future<String?> getMergeBase(String baseTarget) async {
    final mergeBaseResult = await processRunner('git', [
      'merge-base',
      baseTarget,
      'HEAD',
    ]);
    if (mergeBaseResult.exitCode != 0) {
      logProcessResult(
        mergeBaseResult,
        command: 'git merge-base',
        onLog: onLog,
        onError: onError,
      );
      return null;
    }
    return _decodeStdout(mergeBaseResult.stdout).trim();
  }

  Future<bool> _runFsck({
    required List<String> revisions,
    required List<LfsIssue> issues,
    Set<String>? allowedFiles,
  }) async {
    final fsckResult = await processRunner('git', [
      'lfs',
      'fsck',
      '--pointers',
      ...revisions,
    ]);
    if (fsckResult.exitCode == 0) {
      return true;
    }

    logProcessResult(
      fsckResult,
      command: 'git lfs fsck --pointers',
      onLog: onLog,
      onError: onError,
    );

    final combinedOutput =
        '${_decodeStdout(fsckResult.stdout)}\n${_decodeStdout(fsckResult.stderr)}';
    final parsed = parseFsckOutput(combinedOutput);

    if (parsed.isEmpty) {
      final err = _decodeStdout(fsckResult.stderr).trim();
      final out = _decodeStdout(fsckResult.stdout).trim();
      final message = err.isNotEmpty
          ? err
          : (out.isNotEmpty ? out : 'Git LFS fsck check failed');
      issues.add(LfsIssue(filePath: '', message: message));
      return false;
    }

    var addedAny = false;
    for (final issue in parsed) {
      if (allowedFiles == null || allowedFiles.contains(issue.filePath)) {
        issues.add(issue);
        addedAny = true;
      }
    }

    return !addedAny;
  }

  /// Verifies all commits and modified files in a pull request comparing against [baseBranch].
  ///
  /// By default, audits cumulative changes at `HEAD`, aligning with GitHub's
  /// squash-and-merge workflow.
  ///
  /// If [auditIntermediateCommits] is true, audits every intermediate commit on
  /// the PR branch for raw binaries. Only needed for repositories that do not
  /// enforce squash merges (e.g. merge-commit or rebase-merge).
  Future<LfsVerificationResult> verifyPullRequest({
    required String baseBranch,
    bool auditIntermediateCommits = false,
  }) async {
    final issues = <LfsIssue>[];

    final baseTarget = await resolveBaseTarget(baseBranch);
    if (baseTarget == null) {
      issues.add(
        LfsIssue(
          filePath: '',
          message:
              "Git base ref '$baseBranch' not found: Could not resolve base target '$baseBranch' for pull request comparison.",
        ),
      );
      return (isSuccess: false, issues: issues);
    }

    final mergeBase = await getMergeBase(baseTarget);
    if (mergeBase == null) {
      issues.add(
        LfsIssue(
          filePath: '',
          message:
              "Could not determine merge base between '$baseTarget' and HEAD.",
        ),
      );
      return (isSuccess: false, issues: issues);
    }

    final diffResult = await processRunner('git', [
      'diff',
      '-z',
      '--name-only',
      '--diff-filter=ACMR', // cspell:ignore ACMR
      mergeBase,
      'HEAD',
    ]);
    if (diffResult.exitCode != 0) {
      logProcessResult(
        diffResult,
        command: 'git diff',
        onLog: onLog,
        onError: onError,
      );
      issues.add(
        LfsIssue(
          filePath: '',
          message:
              'Failed to diff commits between $mergeBase and HEAD: ${_decodeStdout(diffResult.stderr).trim()}',
        ),
      );
      return (isSuccess: false, issues: issues);
    }

    final diffFiles = _parseNulTerminated(_decodeStdout(diffResult.stdout));
    final normalizedDiffFiles = {
      for (final f in diffFiles) p.posix.normalize(f.replaceAll(r'\', '/')),
    };

    if (auditIntermediateCommits) {
      onLog?.call(
        'Auditing all intermediate commits between $mergeBase and HEAD...',
      );
      await _runFsck(revisions: ['$mergeBase..HEAD'], issues: issues);
    } else {
      onLog?.call('Checking pull request files at HEAD...');
      await _runFsck(
        revisions: ['HEAD'],
        issues: issues,
        allowedFiles: normalizedDiffFiles,
      );
    }

    return (isSuccess: issues.isEmpty, issues: issues);
  }

  /// Verifies all tracked repository files at `HEAD`.
  Future<LfsVerificationResult> verifyTrackedFiles() async {
    final issues = <LfsIssue>[];

    onLog?.call('Checking all tracked repository files at HEAD...');

    await _runFsck(revisions: ['HEAD'], issues: issues);

    return (isSuccess: issues.isEmpty, issues: issues);
  }

  /// Unified verification router for tree verification.
  ///
  /// If [baseBranch] is provided, executes pull request comparison against that branch.
  /// Otherwise, audits all tracked files at HEAD.
  Future<LfsVerificationResult> verify({
    String? baseBranch,
    bool auditIntermediateCommits = false,
  }) async {
    if (!await isLfsInstalled()) {
      return (
        isSuccess: false,
        issues: const [
          LfsIssue(
            filePath: '',
            message:
                'Git LFS is not installed or not found in PATH. Please install Git LFS (https://git-lfs.com) and run "git lfs install".',
          ),
        ],
      );
    }
    return switch (baseBranch?.trim()) {
      final branch? when branch.isNotEmpty => verifyPullRequest(
        baseBranch: branch,
        auditIntermediateCommits: auditIntermediateCommits,
      ),
      _ => verifyTrackedFiles(),
    };
  }
}
