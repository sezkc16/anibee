import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reicon_flutter/reicon_flutter.dart';

import '../models.dart';
import '../settings_store.dart';
import '../widgets/reicon_icon.dart';

/// "Server for this episode" bottom sheet — Anilili style
/// (ref anilili-server-sheet-reference.jpg).
///
/// Title + "Finding sources... N so far" status + fast-servers hint +
/// All / Sub / Dub filter pills + "Checking servers for languages..."
/// status + language pills + server cards in a grid (lightning icon,
/// name, download icon, checkmark when selected, SUB/DUB pill at the
/// bottom; selected card = accent-filled).
///
/// 0.2.6: the bottom row ("Retry {server} servers" + "Close") was
/// removed at the user's order — the sheet closes by picking a
/// server, swipe-down (bottom sheet) or the panel X (slide-over).
/// Nothing else changed.
///
/// M1.1: the server list comes from the store's sources; the SUB/DUB
/// and language filters work over mock per-server language data. Real
/// on-device resolving arrives with milestone 2.
///
/// M2: a Debrid section (TorBox / Real-Debrid cards) appears when the
/// user has saved a key for that service — picking one resolves the
/// episode through the debrid API (cached torrents) instead of Miruro.
/// The returned record carries `debrid` ('torbox' | 'realdebrid') or
/// null for a normal provider server.
Future<({String server, String subDub, String? debrid})?> showServerSheet({
  required BuildContext context,
  required SettingsStore store,
  required String currentServer,
  required String subDub,
  String? currentDebrid,
}) {
  return showModalBottomSheet<({String server, String subDub, String? debrid})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF17171F),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext context) {
      return ServerSheetBody(
        store: store,
        currentServer: currentServer,
        subDub: subDub,
        currentDebrid: currentDebrid,
        onPick: (({String server, String subDub, String? debrid}) result) =>
            Navigator.of(context).pop(result),
        onClose: () => Navigator.of(context).pop(),
      );
    },
  );
}

/// Mock M1.1 language availability per server (real data in M2).
const Map<String, List<String>> kServerLanguages = <String, List<String>>{
  'Miruro': <String>['English'],
  'AniKoto': <String>['English', 'Japanese'],
  'AniSuge': <String>['English'],
  'AniKage': <String>['English'],
  // Anime-Sama is a French site: VOSTFR (Japanese audio +
  // French hardsubs) and VF (French dub). No English audio or
  // subtitles on this source.
  'Anime-Sama': <String>['French'],
};

const List<String> kSheetLanguages = <String>[
  'Any',
  'Arabic',
  'English',
  'French',
  'German',
  'Hindi',
  'Italian',
  'Japanese',
  'Portuguese',
  'Russian',
  'Spanish',
];

/// The server-picker body, usable in two places (0.2.4):
/// - the Anilili-style bottom sheet ([showServerSheet], unchanged);
/// - the right-side slide-over Sources panel in the full player
///   (`compact: true` — single-column list, no drag handle, no
///   fixed 78% height; the panel supplies the frame).
/// Picking a server calls [onPick]; Close calls [onClose].
class ServerSheetBody extends StatefulWidget {
  const ServerSheetBody({
    super.key,
    required this.store,
    required this.currentServer,
    required this.subDub,
    required this.onPick,
    required this.onClose,
    this.currentDebrid,
    this.compact = false,
  });

  final SettingsStore store;
  final String currentServer;
  final String subDub;
  final String? currentDebrid;
  final void Function(({String server, String subDub, String? debrid}))
  onPick;
  final VoidCallback onClose;
  final bool compact;

  @override
  State<ServerSheetBody> createState() => _ServerSheetBodyState();
}

class _ServerSheetBodyState extends State<ServerSheetBody> {
  late String _filter; // All / Sub / Dub
  String _language = 'Any';
  late String _selectedServer;
  bool _checking = true;
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    _filter = widget.subDub == 'Dub' ? 'Dub' : 'Sub';
    _selectedServer = widget.currentServer;
    _runCheck();
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  void _runCheck() {
    _checkTimer?.cancel();
    setState(() => _checking = true);
    _checkTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _checking = false);
    });
  }

  List<({String server, String variant})> get _cards {
    final List<({String server, String variant})> out =
        <({String server, String variant})>[];
    final List<String> variants = _filter == 'All'
        ? <String>['Sub', 'Dub']
        : <String>[_filter];
    for (final ProviderSource source in widget.store.sources) {
      if (!source.enabled) continue;
      final List<String> langs =
          kServerLanguages[source.name] ?? const <String>['English'];
      if (_language != 'Any' && !langs.contains(_language)) continue;
      for (final String variant in variants) {
        out.add((server: source.name, variant: variant));
      }
    }
    return out;
  }

  bool _isSelected(({String server, String variant}) card) {
    return card.server == _selectedServer &&
        ((_filter == 'All' && card.variant == widget.subDub) ||
            _filter == card.variant);
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    final List<({String server, String variant})> cards = _cards;

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!widget.compact) ...<Widget>[
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A48),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (widget.compact) const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Server for this episode',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  Icon(Icons.check_rounded, color: accent, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'Finding sources... ${cards.length} so far',
                    style: TextStyle(
                      color: accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  ReiconIcon(Reicon.outline.bolt, size: 16, color: accent),
                  const SizedBox(width: 6),
                  const Text(
                    'Fast servers usually start quickest',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Debrid section (M2): cached-torrent sources, shown only
            // when the user has saved a key for that service.
            if (widget.store.torboxApiKey != null ||
                widget.store.realDebridApiKey != null) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'DEBRID — CACHED TORRENTS',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: <Widget>[
                    if (widget.store.torboxApiKey != null)
                      Expanded(
                        child: _DebridCard(
                          name: 'TorBox',
                          selected: widget.currentDebrid == 'torbox',
                          accent: accent,
                          onTap: () => widget.onPick((
                            server: 'TorBox',
                            subDub: _filter == 'All'
                                ? widget.subDub
                                : _filter,
                            debrid: 'torbox',
                          )),
                        ),
                      ),
                    if (widget.store.torboxApiKey != null &&
                        widget.store.realDebridApiKey != null)
                      const SizedBox(width: 10),
                    if (widget.store.realDebridApiKey != null)
                      Expanded(
                        child: _DebridCard(
                          name: 'Real-Debrid',
                          selected: widget.currentDebrid == 'realdebrid',
                          accent: accent,
                          onTap: () => widget.onPick((
                            server: 'Real-Debrid',
                            subDub: _filter == 'All'
                                ? widget.subDub
                                : _filter,
                            debrid: 'realdebrid',
                          )),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            // All / Sub / Dub filter pills.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  for (final String f in <String>['All', 'Sub', 'Dub'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _Pill(
                        label: f,
                        selected: _filter == f,
                        accent: accent,
                        onTap: () => setState(() => _filter = f),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  if (_checking)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  else
                    Icon(Icons.check_rounded, color: accent, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    _checking
                        ? 'Checking servers for languages...'
                        : 'Servers checked',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Language pills (horizontal scroll).
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: kSheetLanguages.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (BuildContext context, int index) {
                  final String lang = kSheetLanguages[index];
                  return _Pill(
                    label: lang,
                    selected: _language == lang,
                    accent: accent,
                    onTap: () => setState(() => _language = lang),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // Server cards: 2-column grid in the sheet, single-column
            // list in the side panel.
            Expanded(
              child: cards.isEmpty
                  ? const Center(
                      child: Text(
                        'No servers for this language yet',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    )
                  : widget.compact
                      ? ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: cards.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (BuildContext context, int index) {
                            final ({String server, String variant}) card =
                                cards[index];
                            return SizedBox(
                              height: 64,
                              child: _ServerCard(
                                server: card.server,
                                variant: card.variant,
                                selected: _isSelected(card),
                                accent: accent,
                                onTap: () => widget.onPick((
                                  server: card.server,
                                  subDub: card.variant,
                                  debrid: null,
                                )),
                              ),
                            );
                          },
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 2.1,
                              ),
                          itemCount: cards.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ({String server, String variant}) card =
                                cards[index];
                            return _ServerCard(
                              server: card.server,
                              variant: card.variant,
                              selected: _isSelected(card),
                              accent: accent,
                              onTap: () => widget.onPick((
                                server: card.server,
                                subDub: card.variant,
                                debrid: null,
                              )),
                            );
                          },
                        ),
            ),
          ],
        );

    if (widget.compact) return content;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: content,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0xFF23232F),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Debrid source card (TorBox / Real-Debrid): name + "Cached" pill,
/// accent-filled when selected.
class _DebridCard extends StatelessWidget {
  const _DebridCard({
    required this.name,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0xFF23232F),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ReiconIcon(
                  Reicon.outline.bolt,
                  size: 16,
                  color: selected ? Colors.white : accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'CACHED',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.variant,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String server;
  final String variant;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color iconColor = selected ? Colors.white : accent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0xFF23232F),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ReiconIcon(Reicon.outline.bolt, size: 16, color: iconColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    server,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ReiconIcon(
                  Reicon.outline.download,
                  size: 16,
                  color: selected ? Colors.white70 : Colors.white54,
                ),
                if (selected) ...<Widget>[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ],
              ],
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                variant.toUpperCase(),
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
