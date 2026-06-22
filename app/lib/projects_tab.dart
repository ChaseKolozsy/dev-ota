import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

class ProjectsTab extends StatefulWidget {
  const ProjectsTab({super.key, required this.dio, required this.serverUrl});

  final Dio dio;
  final String serverUrl;

  @override
  State<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<ProjectsTab> {
  bool _loading = false;
  String? _status;
  List<Map<String, dynamic>> _clients = [];
  List<Map<String, dynamic>> _projects = [];
  List<Map<String, dynamic>> _phases = [];
  List<Map<String, dynamic>> _cards = [];
  List<Map<String, dynamic>> _comments = [];
  List<Map<String, dynamic>> _phaseTemplates = [];
  Map<String, dynamic> _emailConfig = {};
  int? _clientFilter;
  int? _projectFilter;
  String _grouping = 'client_project';

  String get _baseUrl => widget.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');

  @override
  void initState() {
    super.initState();
    unawaited(_loadBoard());
  }

  @override
  void didUpdateWidget(covariant ProjectsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) unawaited(_loadBoard());
  }

  int _id(Map<String, dynamic> item) => (item['id'] as num).toInt();

  String _briefError(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      final data = e.response?.data?.toString();
      if (code != null) {
        final detail = data == null || data.isEmpty
            ? ''
            : ' ${data.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim()}';
        return 'HTTP $code$detail';
      }
      return e.message ?? e.type.name;
    }
    return e.toString();
  }

  Future<void> _loadBoard() async {
    if (_baseUrl.isEmpty) return;
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final resp = await widget.dio.get('$_baseUrl/projects/board');
      final data = Map<String, dynamic>.from(resp.data as Map);
      if (!mounted) return;
      setState(() {
        _clients = _asMapList(data['clients']);
        _projects = _asMapList(data['projects']);
        _phases = _asMapList(data['phases']);
        _cards = _asMapList(data['cards']);
        _comments = _asMapList(data['comments']);
        _phaseTemplates = _asMapList(data['phaseTemplates']);
        _emailConfig = data['emailConfig'] is Map
            ? Map<String, dynamic>.from(data['emailConfig'] as Map)
            : {};
        if (_clientFilter != null &&
            !_clients.any((item) => _id(item) == _clientFilter)) {
          _clientFilter = null;
        }
        if (_projectFilter != null &&
            !_projects.any((item) => _id(item) == _projectFilter)) {
          _projectFilter = null;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Projects load failed: ${_briefError(e)}');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Map<String, dynamic>? _clientById(int id) {
    for (final client in _clients) {
      if (_id(client) == id) return client;
    }
    return null;
  }

  Map<String, dynamic>? _projectById(int id) {
    for (final project in _projects) {
      if (_id(project) == id) return project;
    }
    return null;
  }

  List<Map<String, dynamic>> _phasesForProject(int projectId) {
    return _phases.where((item) => item['projectId'] == projectId).toList()
      ..sort((a, b) => (a['order'] as num).compareTo(b['order'] as num));
  }

  List<Map<String, dynamic>> _cardsForPhase(int phaseId) {
    return _cards.where((item) => item['phaseId'] == phaseId).toList()
      ..sort((a, b) => (a['order'] as num).compareTo(b['order'] as num));
  }

  List<Map<String, dynamic>> _commentsForCard(int cardId) {
    return _comments.where((item) => item['cardId'] == cardId).toList()..sort(
      (a, b) => a['createdAt'].toString().compareTo(b['createdAt'].toString()),
    );
  }

  List<Map<String, dynamic>> get _visibleProjects {
    final items = _projects.where((project) {
      if (_projectFilter != null && _id(project) != _projectFilter) {
        return false;
      }
      if (_clientFilter != null && project['clientId'] != _clientFilter) {
        return false;
      }
      return true;
    }).toList();
    items.sort((a, b) {
      if (_grouping == 'project_client') {
        return a['name'].toString().compareTo(b['name'].toString());
      }
      final clientA =
          _clientById((a['clientId'] as num).toInt())?['name'] ?? '';
      final clientB =
          _clientById((b['clientId'] as num).toInt())?['name'] ?? '';
      final clientCompare = clientA.toString().compareTo(clientB.toString());
      if (clientCompare != 0) return clientCompare;
      return a['name'].toString().compareTo(b['name'].toString());
    });
    return items;
  }

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      final resp = await widget.dio.post('$_baseUrl$path', data: data);
      return Map<String, dynamic>.from(resp.data as Map);
    } catch (e) {
      if (mounted) setState(() => _status = _briefError(e));
      return null;
    }
  }

  Future<Map<String, dynamic>?> _patch(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      final resp = await widget.dio.patch('$_baseUrl$path', data: data);
      return Map<String, dynamic>.from(resp.data as Map);
    } catch (e) {
      if (mounted) setState(() => _status = _briefError(e));
      return null;
    }
  }

  Future<void> _createClientDialog() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New client'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await _post('/projects/clients', {
        'name': name.text.trim(),
        'email': email.text.trim(),
        'notes': notes.text.trim(),
      });
      await _loadBoard();
    }
  }

  Future<void> _createProjectDialog() async {
    if (_clients.isEmpty) {
      await _createClientDialog();
      if (!mounted) return;
      if (_clients.isEmpty) return;
    }
    final name = TextEditingController();
    final repo = TextEditingController();
    final appId = TextEditingController();
    int clientId = _clientFilter ?? _id(_clients.first);
    int? templateId = _phaseTemplates.isEmpty
        ? null
        : _id(_phaseTemplates.first);
    var applyTemplate = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New project'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: clientId,
                  decoration: const InputDecoration(labelText: 'Client'),
                  items: _clients
                      .map(
                        (client) => DropdownMenuItem<int>(
                          value: _id(client),
                          child: Text(client['name'].toString()),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setDialogState(() => clientId = value);
                  },
                ),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Project name'),
                ),
                TextField(
                  controller: repo,
                  decoration: const InputDecoration(labelText: 'Repo URL'),
                ),
                TextField(
                  controller: appId,
                  decoration: const InputDecoration(labelText: 'Build app id'),
                ),
                SwitchListTile(
                  value: applyTemplate,
                  onChanged: (value) =>
                      setDialogState(() => applyTemplate = value),
                  title: const Text('Create default phases'),
                  contentPadding: EdgeInsets.zero,
                ),
                if (applyTemplate && _phaseTemplates.isNotEmpty)
                  DropdownButtonFormField<int>(
                    initialValue: templateId,
                    decoration: const InputDecoration(
                      labelText: 'Phase template',
                    ),
                    items: _phaseTemplates
                        .map(
                          (template) => DropdownMenuItem<int>(
                            value: _id(template),
                            child: Text(template['name'].toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => templateId = value),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await _post('/projects/projects', {
        'clientId': clientId,
        'name': name.text.trim(),
        'repoUrl': repo.text.trim(),
        'buildAppId': appId.text.trim(),
        'applyTemplate': applyTemplate,
        ...?templateId == null ? null : {'templateId': templateId},
      });
      await _loadBoard();
    }
  }

  Future<void> _createPhaseDialog(Map<String, dynamic> project) async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New phase'),
        content: TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Phase name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await _post('/projects/phases', {
        'projectId': _id(project),
        'name': name.text.trim(),
      });
      await _loadBoard();
    }
  }

  Future<void> _createCardDialog(Map<String, dynamic> phase) async {
    final title = TextEditingController();
    final body = TextEditingController();
    var needsClient = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New card'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: body,
                  decoration: const InputDecoration(labelText: 'Details'),
                  minLines: 3,
                  maxLines: 6,
                ),
                SwitchListTile(
                  value: needsClient,
                  onChanged: (value) =>
                      setDialogState(() => needsClient = value),
                  title: const Text('Needs client action'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await _post('/projects/cards', {
        'phaseId': _id(phase),
        'title': title.text.trim(),
        'body': body.text.trim(),
        'status': needsClient ? 'waiting_client' : 'todo',
        'clientActionRequired': needsClient,
      });
      await _loadBoard();
    }
  }

  Future<void> _editCardDialog(Map<String, dynamic> card) async {
    final title = TextEditingController(text: card['title'].toString());
    final body = TextEditingController(text: card['body'].toString());
    final comment = TextEditingController();
    var status = card['status'].toString();
    var needsClient = card['clientActionRequired'] == true;
    final cardId = _id(card);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final comments = _commentsForCard(cardId);
          return AlertDialog(
            title: const Text('Card'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: title,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    TextField(
                      controller: body,
                      decoration: const InputDecoration(labelText: 'Details'),
                      minLines: 3,
                      maxLines: 8,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const [
                        DropdownMenuItem(value: 'todo', child: Text('To do')),
                        DropdownMenuItem(value: 'doing', child: Text('Doing')),
                        DropdownMenuItem(
                          value: 'waiting_client',
                          child: Text('Waiting client'),
                        ),
                        DropdownMenuItem(
                          value: 'review',
                          child: Text('Review'),
                        ),
                        DropdownMenuItem(value: 'done', child: Text('Done')),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => status = value);
                      },
                    ),
                    SwitchListTile(
                      value: needsClient,
                      onChanged: (value) =>
                          setDialogState(() => needsClient = value),
                      title: const Text('Needs client action'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(),
                    Text(
                      'Comments',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (comments.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No comments yet.'),
                      ),
                    for (final item in comments.take(20))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${item['authorType']} • ${item['createdAt']}',
                        ),
                        subtitle: Text(item['body'].toString()),
                      ),
                    TextField(
                      controller: comment,
                      decoration: const InputDecoration(
                        labelText: 'Add comment',
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _emailDraftDialog(
                  card,
                  event: needsClient ? 'client_action' : 'update',
                ),
                child: const Text('Email'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (ok == true) {
      await _patch('/projects/cards/$cardId', {
        'title': title.text.trim(),
        'body': body.text.trim(),
        'status': status,
        'clientActionRequired': needsClient,
      });
      if (comment.text.trim().isNotEmpty) {
        await _post('/projects/cards/$cardId/comments', {
          'authorType': 'me',
          'body': comment.text.trim(),
        });
      }
      await _loadBoard();
    }
  }

  Future<Map<String, dynamic>> _phaseUpdateCard(
    Map<String, dynamic> phase,
  ) async {
    final phaseId = _id(phase);
    final title = 'Phase update: ${phase['name']}';
    final existing = _cardsForPhase(
      phaseId,
    ).where((card) => card['title'] == title);
    if (existing.isNotEmpty) return existing.first;
    final response = await _post('/projects/cards', {
      'phaseId': phaseId,
      'title': title,
      'body': 'Client-visible update card for the ${phase['name']} phase.',
      'status': 'review',
    });
    await _loadBoard();
    final item = response?['item'];
    return item is Map
        ? Map<String, dynamic>.from(item)
        : _cardsForPhase(phaseId).last;
  }

  Future<void> _notifyPhase(Map<String, dynamic> phase, String event) async {
    final nextStatus = event == 'phase_completed' ? 'completed' : 'active';
    await _patch('/projects/phases/${_id(phase)}', {'status': nextStatus});
    await _loadBoard();
    final card = await _phaseUpdateCard(phase);
    await _emailDraftDialog(card, event: event);
  }

  Future<void> _emailDraftDialog(
    Map<String, dynamic> card, {
    required String event,
  }) async {
    final preview = await _post('/projects/cards/${_id(card)}/email/preview', {
      'event': event,
    });
    if (preview == null || !mounted) return;
    final subject = TextEditingController(
      text: preview['subject']?.toString() ?? '',
    );
    final message = TextEditingController(
      text: preview['message']?.toString() ?? '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Email client'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('To: ${preview['to'] ?? '(missing client email)'}'),
                Text('Reply-To: ${preview['replyTo'] ?? ''}'),
                const SizedBox(height: 8),
                TextField(
                  controller: subject,
                  decoration: const InputDecoration(labelText: 'Subject'),
                ),
                TextField(
                  controller: message,
                  decoration: const InputDecoration(labelText: 'Message'),
                  minLines: 5,
                  maxLines: 10,
                ),
                if (preview['postmarkConfigured'] != true)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Postmark is not configured. Save email settings before sending.',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final sent = await _post('/projects/cards/${_id(card)}/email/send', {
        'event': event,
        'subject': subject.text.trim(),
        'message': message.text.trim(),
      });
      if (sent != null && mounted) setState(() => _status = 'Email sent.');
      await _loadBoard();
    }
  }

  Future<void> _emailSettingsDialog() async {
    final fromEmail = TextEditingController(
      text: _emailConfig['fromEmail']?.toString() ?? '',
    );
    final fromName = TextEditingController(
      text: _emailConfig['fromName']?.toString() ?? 'DevOTA',
    );
    final inboundDomain = TextEditingController(
      text: _emailConfig['inboundDomain']?.toString() ?? '',
    );
    final stream = TextEditingController(
      text: _emailConfig['messageStream']?.toString() ?? 'outbound',
    );
    final relayUrl = TextEditingController(
      text: _emailConfig['relayPullUrl']?.toString() ?? '',
    );
    final postmarkToken = TextEditingController();
    final relayToken = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Email settings'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: fromEmail,
                  decoration: const InputDecoration(labelText: 'From email'),
                ),
                TextField(
                  controller: fromName,
                  decoration: const InputDecoration(labelText: 'From name'),
                ),
                TextField(
                  controller: inboundDomain,
                  decoration: const InputDecoration(
                    labelText: 'Inbound domain',
                  ),
                ),
                TextField(
                  controller: stream,
                  decoration: const InputDecoration(
                    labelText: 'Message stream',
                  ),
                ),
                TextField(
                  controller: relayUrl,
                  decoration: const InputDecoration(
                    labelText: 'Relay pull URL',
                  ),
                ),
                TextField(
                  controller: postmarkToken,
                  decoration: InputDecoration(
                    labelText: _emailConfig['postmarkConfigured'] == true
                        ? 'Postmark token (configured)'
                        : 'Postmark token',
                  ),
                  obscureText: true,
                ),
                TextField(
                  controller: relayToken,
                  decoration: InputDecoration(
                    labelText: _emailConfig['relayTokenConfigured'] == true
                        ? 'Relay token (configured)'
                        : 'Relay token',
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final payload = {
        'fromEmail': fromEmail.text.trim(),
        'fromName': fromName.text.trim(),
        'inboundDomain': inboundDomain.text.trim(),
        'messageStream': stream.text.trim(),
        'relayPullUrl': relayUrl.text.trim(),
        if (postmarkToken.text.trim().isNotEmpty)
          'postmarkServerToken': postmarkToken.text.trim(),
        if (relayToken.text.trim().isNotEmpty)
          'relayToken': relayToken.text.trim(),
      };
      await _post('/projects/email/config', payload);
      await _loadBoard();
    }
  }

  Future<void> _pullReplies() async {
    final response = await _post('/projects/mail/pull', {});
    if (response != null && mounted) {
      final imported = response['imported'] is List
          ? (response['imported'] as List).length
          : 0;
      final errors = response['errors'] is List
          ? (response['errors'] as List).length
          : 0;
      setState(
        () => _status =
            'Pulled $imported replies${errors > 0 ? ', $errors errors' : ''}.',
      );
    }
    await _loadBoard();
  }

  Future<void> _updatePhaseStatus(
    Map<String, dynamic> phase,
    String status,
  ) async {
    await _patch('/projects/phases/${_id(phase)}', {'status': status});
    await _loadBoard();
  }

  Future<void> _updateCardStatus(
    Map<String, dynamic> card,
    String status,
  ) async {
    await _patch('/projects/cards/${_id(card)}', {'status': status});
    await _loadBoard();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Column(
            children: [
              _buildProjectsHeader(theme),
              const SizedBox(height: 8),
              _buildFilters(theme),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _status!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildBoard(theme)),
      ],
    );
  }

  Widget _buildProjectsHeader(ThemeData theme) {
    final title = Text(
      'Projects',
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final actions = [
      IconButton.filledTonal(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh',
        onPressed: _loading ? null : _loadBoard,
      ),
      IconButton.filledTonal(
        icon: const Icon(Icons.mail_outline),
        tooltip: 'Email settings',
        onPressed: _emailSettingsDialog,
      ),
      IconButton.filledTonal(
        icon: const Icon(Icons.mark_email_read_outlined),
        tooltip: 'Pull replies',
        onPressed: _pullReplies,
      ),
      IconButton.filled(
        icon: const Icon(Icons.person_add_alt),
        tooltip: 'Add client',
        onPressed: _createClientDialog,
      ),
      IconButton.filled(
        icon: const Icon(Icons.add_task),
        tooltip: 'Add project',
        onPressed: _createProjectDialog,
      ),
    ];
    final actionWrap = Wrap(spacing: 6, runSpacing: 6, children: actions);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 4), actionWrap],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            actionWrap,
          ],
        );
      },
    );
  }

  Widget _buildFilters(ThemeData theme) {
    final projectItems = _projects
        .where(
          (project) =>
              _clientFilter == null || project['clientId'] == _clientFilter,
        )
        .toList();
    final clientDropdown = DropdownButtonFormField<int?>(
      initialValue: _clientFilter,
      decoration: const InputDecoration(
        labelText: 'Client',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('All clients')),
        ..._clients.map(
          (client) => DropdownMenuItem<int?>(
            value: _id(client),
            child: Text(
              client['name'].toString(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: (value) => setState(() {
        _clientFilter = value;
        if (value != null &&
            _projectFilter != null &&
            _projectById(_projectFilter!)?['clientId'] != value) {
          _projectFilter = null;
        }
      }),
    );
    final projectDropdown = DropdownButtonFormField<int?>(
      initialValue: _projectFilter,
      decoration: const InputDecoration(
        labelText: 'Project',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('All projects')),
        ...projectItems.map(
          (project) => DropdownMenuItem<int?>(
            value: _id(project),
            child: Text(
              project['name'].toString(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: (value) => setState(() => _projectFilter = value),
    );
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 460) {
              return Column(
                children: [
                  clientDropdown,
                  const SizedBox(height: 8),
                  projectDropdown,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: clientDropdown),
                const SizedBox(width: 8),
                Expanded(child: projectDropdown),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'client_project',
                  label: Text('Client -> Project'),
                ),
                ButtonSegment(
                  value: 'project_client',
                  label: Text('Project -> Client'),
                ),
              ],
              selected: {_grouping},
              onSelectionChanged: (values) =>
                  setState(() => _grouping = values.first),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBoard(ThemeData theme) {
    if (_clients.isEmpty) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Create first client'),
          onPressed: _createClientDialog,
        ),
      );
    }
    final visibleProjects = _visibleProjects;
    if (visibleProjects.isEmpty) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.add_task),
          label: const Text('Create project'),
          onPressed: _createProjectDialog,
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: visibleProjects.length,
      itemBuilder: (context, index) =>
          _buildProjectSection(theme, visibleProjects[index]),
    );
  }

  Widget _buildProjectSection(ThemeData theme, Map<String, dynamic> project) {
    final client = _clientById((project['clientId'] as num).toInt());
    final phases = _phasesForProject(_id(project));
    final title = _grouping == 'project_client'
        ? '${project['name']} • ${client?['name'] ?? 'Client'}'
        : '${client?['name'] ?? 'Client'} • ${project['name']}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(title, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if ((client?['email'] ?? '').toString().isNotEmpty)
              client!['email'],
            project['status'],
            if ((project['buildAppId'] ?? '').toString().isNotEmpty)
              project['buildAppId'],
          ].join('  •  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'Add phase',
          onPressed: () => _createPhaseDialog(project),
        ),
        children: [
          if (phases.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add phase'),
                onPressed: () => _createPhaseDialog(project),
              ),
            )
          else
            SizedBox(
              height: 420,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: phases
                    .map((phase) => _buildPhaseColumn(theme, phase))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPhaseColumn(ThemeData theme, Map<String, dynamic> phase) {
    final cards = _cardsForPhase(_id(phase));
    return SizedBox(
      width: 286,
      child: Card(
        color: theme.colorScheme.surfaceContainerHighest,
        margin: const EdgeInsets.only(right: 10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      phase['name'].toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Phase actions',
                    onSelected: (value) {
                      if (value == 'start') {
                        unawaited(_notifyPhase(phase, 'phase_started'));
                      } else if (value == 'complete') {
                        unawaited(_notifyPhase(phase, 'phase_completed'));
                      } else {
                        unawaited(_updatePhaseStatus(phase, value));
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'start',
                        child: Text('Start + email'),
                      ),
                      PopupMenuItem(
                        value: 'complete',
                        child: Text('Complete + email'),
                      ),
                      PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'not_started',
                        child: Text('Not started'),
                      ),
                      PopupMenuItem(value: 'active', child: Text('Active')),
                      PopupMenuItem(
                        value: 'waiting_client',
                        child: Text('Waiting client'),
                      ),
                      PopupMenuItem(
                        value: 'completed',
                        child: Text('Completed'),
                      ),
                    ],
                  ),
                ],
              ),
              Text(
                phase['status'].toString(),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Card'),
                onPressed: () => _createCardDialog(phase),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: cards.isEmpty
                    ? Center(
                        child: Text(
                          'No cards',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView(
                        children: cards
                            .map((card) => _buildCardTile(theme, card))
                            .toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardTile(ThemeData theme, Map<String, dynamic> card) {
    final commentCount = _commentsForCard(_id(card)).length;
    final needsClient = card['clientActionRequired'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _editCardDialog(card),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      card['title'].toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Card status',
                    onSelected: (value) => _updateCardStatus(card, value),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'todo', child: Text('To do')),
                      PopupMenuItem(value: 'doing', child: Text('Doing')),
                      PopupMenuItem(
                        value: 'waiting_client',
                        child: Text('Waiting client'),
                      ),
                      PopupMenuItem(value: 'review', child: Text('Review')),
                      PopupMenuItem(value: 'done', child: Text('Done')),
                    ],
                  ),
                ],
              ),
              if ((card['body'] ?? '').toString().isNotEmpty)
                Text(
                  card['body'].toString(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(card['status'].toString()),
                  ),
                  if (needsClient)
                    const Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(Icons.priority_high, size: 16),
                      label: Text('client'),
                    ),
                  if (commentCount > 0)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.comment, size: 16),
                      label: Text('$commentCount'),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.mail_outline, size: 20),
                    tooltip: 'Email client',
                    onPressed: () => _emailDraftDialog(
                      card,
                      event: needsClient ? 'client_action' : 'update',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
