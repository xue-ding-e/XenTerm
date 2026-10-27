/// Known Hosts — the core's TOFU `known_hosts` store. Lists the real remembered
/// keys (host:port, algorithm, SHA256 fingerprint) and removes entries; no
/// fixture rows.
library;

import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../bridge/native_bridge.dart';
import '../../l10n/app_language.dart';
import '../../theme/app_field.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primitives.dart';

typedef KnownHostLoader = Future<List<KnownHost>> Function();
typedef KnownHostDeleter = Future<CoreWriteResult> Function(String id);

class KnownHostsScreen extends StatefulWidget {
  final KnownHostLoader? loadHosts;
  final KnownHostDeleter? deleteHost;

  const KnownHostsScreen({super.key, this.loadHosts, this.deleteHost});

  @override
  State<KnownHostsScreen> createState() => _KnownHostsScreenState();
}

class _KnownHostsScreenState extends State<KnownHostsScreen> {
  List<KnownHost> _hosts = const [];
  bool _loading = true;
  bool _reloadInFlight = false;
  String? _error;
  String? _notice;
  String? _confirming;
  String? _removing;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    // Guard the operation, not just the next rendered button state: two
    // activations in the same frame must not race and publish stale results.
    if (_reloadInFlight) return;
    _reloadInFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final hosts = await (widget.loadHosts ?? loadKnownHostsFromCore)();
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is NativeBridgeError ? error.message : '$error';
      });
    } finally {
      _reloadInFlight = false;
    }
  }

  Future<void> _remove(KnownHost host) async {
    // The confirmation stays visible while the core is writing. A second
    // activation must not issue another delete, including before the next frame.
    if (_removing != null || _confirming != host.id) return;
    setState(() {
      _removing = host.id;
      _error = null;
      _notice = null;
    });
    try {
      final result = await (widget.deleteHost ?? deleteKnownHostFromCore)(host.id);
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _error = result.error ?? 'Could not remove the key');
        return;
      }
      setState(() {
        _confirming = null;
        _hosts = _hosts.where((entry) => entry.id != host.id).toList();
      });
      await _reload(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  Future<void> _copy(String value) async {
    try {
      // Copy the original data, never the abbreviated display text.
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) setState(() => _notice = 'Copied');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  List<KnownHost> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _hosts;
    return _hosts
        .where(
          (h) =>
              h.id.toLowerCase().contains(query) ||
              h.keyType.toLowerCase().contains(query) ||
              h.fingerprint.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hosts = _filtered;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppLanguage.tr(context, 'Known Hosts'),
                      style: theme.typography.bold.copyWith(fontSize: 18),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _KnownHostAction(
                    key: const ValueKey('known-host-refresh'),
                    icon: LucideIcons.refreshCw,
                    label: AppLanguage.tr(context, 'Refresh'),
                    onPressed: _loading || _confirming != null || _removing != null
                        ? null
                        : () => _reload(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                AppLanguage.tr(context, '{shown} of {total} known hosts', {
                  'shown': hosts.length,
                  'total': _hosts.length,
                }),
                key: const ValueKey('known-host-count'),
                style: TextStyle(color: XtColors.textTertiary(context)),
              ),
              const SizedBox(height: 12),
              XtField(
                key: const ValueKey('known-host-search'),
                controller: _search,
                onChanged: (value) => setState(() {
                  _query = value;
                  if (_removing == null) _confirming = null;
                }),
                placeholder: AppLanguage.tr(context, 'Search known hosts'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  AppLanguage.tr(context, _error!),
                  key: const ValueKey('known-host-error'),
                  style: TextStyle(color: XtColors.danger(context)),
                ),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Text(AppLanguage.tr(context, _notice!)),
              ],
              const SizedBox(height: 12),
              Expanded(child: _body(hosts)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(List<KnownHost> hosts) {
    if (_loading) {
      return Center(child: Text(AppLanguage.tr(context, 'Loading known hosts…')));
    }
    if (hosts.isEmpty && _error != null) {
      return Center(
        child: _KnownHostAction(
          label: AppLanguage.tr(context, 'Retry'),
          onPressed: () => _reload(),
        ),
      );
    }
    if (hosts.isEmpty) {
      return SingleChildScrollView(
        child: XtEmptyState(
          icon: LucideIcons.fingerprint,
          title: AppLanguage.tr(
            context,
            _hosts.isEmpty ? 'No known hosts yet' : 'No matches',
          ),
          message: AppLanguage.tr(
            context,
            _hosts.isEmpty
                ? 'Host keys are remembered after you accept them on connect.'
                : 'Try a different search.',
          ),
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('known-host-list'),
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: hosts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final host = hosts[index];
        return KnownHostCard(
          key: ValueKey(host.id),
          host: host,
          confirming: _confirming == host.id,
          busy: _removing != null,
          onRemove: () => setState(() {
            _confirming = host.id;
            _notice = null;
          }),
          onCancel: () => setState(() => _confirming = null),
          onConfirm: () => _remove(host),
          onCopyAddress: () => _copy(host.id),
          onCopyFingerprint: () => _copy(host.fingerprint),
        );
      },
    );
  }
}

class KnownHostCard extends StatelessWidget {
  final KnownHost host;
  final VoidCallback onRemove;
  final bool confirming;
  final bool busy;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final VoidCallback? onCopyAddress;
  final VoidCallback? onCopyFingerprint;

  const KnownHostCard({
    super.key,
    required this.host,
    required this.onRemove,
    this.confirming = false,
    this.busy = false,
    this.onCancel,
    this.onConfirm,
    this.onCopyAddress,
    this.onCopyFingerprint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fingerprint = host.fingerprint.isEmpty
        ? AppLanguage.tr(context, 'unreadable key entry')
        : host.fingerprint;
    return XtCard(
      key: ValueKey('known-host-${host.id}'),
      padding: const EdgeInsets.all(14),
      radius: XtRadius.cardLarge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.shieldCheck, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  host.id,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.semiBold.copyWith(fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: XtBadge(label: _algorithmLabel(host.keyType)),
          ),
          const SizedBox(height: 6),
          Text(
            fingerprint,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontFamilyFallback: const ['Menlo', 'Courier New'],
              fontSize: 12,
              color: XtColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 8),
          if (confirming) ...[
            Text(
              AppLanguage.tr(
                context,
                'Forget the remembered key for “{host}”? Verify the server key again before accepting it on the next connection.',
                {'host': host.id},
              ),
              key: ValueKey('known-host-confirmation-${host.id}'),
              style: TextStyle(color: XtColors.dangerText(context)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _KnownHostAction(
                  key: ValueKey('known-host-cancel-${host.id}'),
                  label: AppLanguage.tr(context, 'Cancel'),
                  autofocus: true,
                  onPressed: busy ? null : onCancel,
                ),
                _KnownHostAction(
                  key: ValueKey('known-host-confirm-${host.id}'),
                  icon: LucideIcons.trash2,
                  label: AppLanguage.tr(context, busy ? 'Removing…' : 'Forget this key'),
                  variant: XtActionVariant.danger,
                  onPressed: busy ? null : onConfirm,
                ),
              ],
            ),
          ] else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _KnownHostAction(
                  key: ValueKey('known-host-copy-address-${host.id}'),
                  icon: LucideIcons.copy,
                  label: AppLanguage.tr(context, 'Copy address'),
                  onPressed: onCopyAddress,
                ),
                _KnownHostAction(
                  key: ValueKey('known-host-copy-fingerprint-${host.id}'),
                  icon: LucideIcons.copy,
                  label: AppLanguage.tr(context, 'Copy fingerprint'),
                  onPressed: host.fingerprint.isEmpty ? null : onCopyFingerprint,
                ),
                _KnownHostAction(
                  key: ValueKey('known-host-remove-${host.id}'),
                  icon: LucideIcons.trash2,
                  label: AppLanguage.tr(context, 'Forget this key'),
                  variant: XtActionVariant.danger,
                  onPressed: busy ? null : onRemove,
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _algorithmLabel(String type) {
    final lower = type.toLowerCase();
    if (lower.contains('ed25519')) return 'ED25519';
    if (lower.contains('rsa')) return 'RSA';
    if (lower.contains('ecdsa')) return 'ECDSA';
    return type.isEmpty ? 'KEY' : type.toUpperCase();
  }
}

/// Keep the existing action appearance, but make this page's always-visible
/// actions reachable by Tab and activatable with Enter/Space as well as mouse.
class _KnownHostAction extends StatefulWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;
  final XtActionVariant variant;
  final bool autofocus;

  const _KnownHostAction({
    super.key,
    this.icon,
    required this.label,
    this.onPressed,
    this.variant = XtActionVariant.ghost,
    this.autofocus = false,
  });

  @override
  State<_KnownHostAction> createState() => _KnownHostActionState();
}

class _KnownHostActionState extends State<_KnownHostAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: widget.onPressed != null,
      autofocus: widget.autofocus,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
            ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: widget.onPressed != null,
        label: widget.label,
        onTap: widget.onPressed,
        child: ExcludeSemantics(
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(XtRadius.card),
              border: Border.all(
                color: _focused ? XtColors.accent(context) : Colors.transparent,
                width: 2,
              ),
            ),
            child: XtActionButton(
              icon: widget.icon,
              label: widget.label,
              variant: widget.variant,
              onPressed: widget.onPressed,
            ),
          ),
        ),
      ),
    );
  }
}
