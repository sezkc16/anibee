import 'package:flutter/material.dart';

class Anime {
  const Anime({
    required this.id,
    required this.title,
    required this.rating,
    required this.year,
    required this.episodeCount,
    required this.genres,
    required this.synopsis,
    required this.gradient,
    this.posterUrl,
    this.anilistId,
    this.malId,
    this.currentEpisode,
    this.minutesLeft,
    this.isSaved = false,
    this.nextEpisode,
    this.nextEpisodeIn,
    this.nextEpisodeAt,
  });

  final String id;
  final String title;
  final double rating;
  final int year;
  final int episodeCount;
  final List<String> genres;
  final String synopsis;
  final List<Color> gradient;

  /// Real cover poster URL (AniList CDN s4, or TMDB w500). Null = no
  /// poster yet; the UI falls back to the gradient art.
  final String? posterUrl;

  /// AniList media id (from the s4 poster URL where known, else
  /// resolved at play time via AniList search). Needed for Miruro
  /// resolve (justanime API) and list sync.
  final int? anilistId;

  /// MyAnimeList id (from AniList idMal). Needed for MAL list sync.
  final int? malId;

  /// Continue Watching state (null = not started).
  final int? currentEpisode;
  final int? minutesLeft;
  final bool isSaved;

  /// Next-episode countdown for ongoing anime (null = finished / unknown):
  /// "Episode 9 in 6d 20h · Nov 29 at 22:05" (Miruro style).
  final int? nextEpisode;
  final String? nextEpisodeIn;
  final String? nextEpisodeAt;

  double get progress {
    if (currentEpisode == null || episodeCount == 0) return 0;
    return (currentEpisode! / episodeCount).clamp(0.0, 1.0);
  }

  Anime copyWith({
    bool? isSaved,
    int? anilistId,
    int? malId,
    int? episodeCount,
    int? currentEpisode,
    int? minutesLeft,
    int? nextEpisode,
    String? nextEpisodeIn,
    String? nextEpisodeAt,
    String? synopsis,
  }) {
    return Anime(
      id: id,
      title: title,
      rating: rating,
      year: year,
      episodeCount: episodeCount ?? this.episodeCount,
      genres: genres,
      synopsis: synopsis ?? this.synopsis,
      gradient: gradient,
      posterUrl: posterUrl,
      anilistId: anilistId ?? this.anilistId,
      malId: malId ?? this.malId,
      currentEpisode: currentEpisode ?? this.currentEpisode,
      minutesLeft: minutesLeft ?? this.minutesLeft,
      isSaved: isSaved ?? this.isSaved,
      nextEpisode: nextEpisode ?? this.nextEpisode,
      nextEpisodeIn: nextEpisodeIn ?? this.nextEpisodeIn,
      nextEpisodeAt: nextEpisodeAt ?? this.nextEpisodeAt,
    );
  }

  /// 0.2.11: JSON for AniList-sync persistence + backup/restore.
  /// Gradient is a UI constant (not per-title data) — it is NOT
  /// stored; fromJson restores the default purple gradient.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'rating': rating,
      'year': year,
      'episodeCount': episodeCount,
      'genres': genres,
      'synopsis': synopsis,
      'posterUrl': posterUrl,
      'anilistId': anilistId,
      'malId': malId,
      'currentEpisode': currentEpisode,
      'minutesLeft': minutesLeft,
      'isSaved': isSaved,
      'nextEpisode': nextEpisode,
      'nextEpisodeIn': nextEpisodeIn,
      'nextEpisodeAt': nextEpisodeAt,
    };
  }

  static Anime? fromJson(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    final String? title = json['title'] as String?;
    if (id == null || id.isEmpty || title == null || title.isEmpty) {
      return null;
    }
    return Anime(
      id: id,
      title: title,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      year: (json['year'] as num?)?.toInt() ?? 0,
      episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
      genres: (json['genres'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          <String>[],
      synopsis: json['synopsis'] as String? ?? '',
      gradient: const <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
      posterUrl: json['posterUrl'] as String?,
      anilistId: (json['anilistId'] as num?)?.toInt(),
      malId: (json['malId'] as num?)?.toInt(),
      currentEpisode: (json['currentEpisode'] as num?)?.toInt(),
      minutesLeft: (json['minutesLeft'] as num?)?.toInt(),
      isSaved: json['isSaved'] as bool? ?? false,
      nextEpisode: (json['nextEpisode'] as num?)?.toInt(),
      nextEpisodeIn: json['nextEpisodeIn'] as String?,
      nextEpisodeAt: json['nextEpisodeAt'] as String?,
    );
  }
}

class Episode {
  const Episode({
    required this.number,
    required this.title,
    required this.duration,
    required this.synopsis,
    required this.airDate,
    required this.hasDub,
    this.thumbnailUrl,
  });

  final int number;
  final String title;
  final String duration;

  /// 2-line synopsis shown on the episode card (M1 mock; M2 = real data).
  final String synopsis;

  /// Air date, e.g. "Oct 4, 2026".
  final String airDate;

  /// True when a dubbed track exists (drives the Sub & Dub filter).
  final bool hasDub;

  /// Per-episode thumbnail from AniList `streamingEpisodes` (0.2.9).
  /// Null = AniList has no thumbnail for this episode → the card
  /// falls back to the anime poster. Never faked or derived.
  final String? thumbnailUrl;

  Episode copyWith({String? thumbnailUrl}) {
    return Episode(
      number: number,
      title: title,
      duration: duration,
      synopsis: synopsis,
      airDate: airDate,
      hasDub: hasDub,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    );
  }
}

class ProviderSource {
  const ProviderSource({
    required this.name,
    required this.tagline,
    required this.enabled,
    this.preferred = false,
  });

  final String name;
  final String tagline;
  final bool enabled;
  final bool preferred;

  ProviderSource copyWith({bool? enabled, bool? preferred}) {
    return ProviderSource(
      name: name,
      tagline: tagline,
      enabled: enabled ?? this.enabled,
      preferred: preferred ?? this.preferred,
    );
  }
}

/// Real-anime catalogue (M1.1). Posters: AniList CDN (s4) where
/// source-verified, else TMDB w500 (HTTP 200 verified from the VM).
/// Metadata (title/year/rating/synopsis) is TMDB data; episode
/// counts are the aired totals. M2 replaces this with live AniList.
List<Anime> mockCatalogue() {
  return <Anime>[
    const Anime(
      id: 'solo-leveling',
      title: 'Solo Leveling',
      rating: 4.3,
      year: 2024,
      episodeCount: 25,
      genres: <String>['Action', 'Fantasy', 'Adventure'],
      synopsis: 'They say whatever doesn’t kill you makes you stronger, but that’s not the case for the world’s weakest hunter Sung Jinwoo. After being brutally slaughtered by monsters in a high-ranking dungeon, Jinwoo came back with...',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx151807-it355ZgzquUd.png',
      anilistId: 151807,
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
      currentEpisode: 7,
      minutesLeft: 9,
    ),
    const Anime(
      id: 'jujutsu-kaisen',
      title: 'JUJUTSU KAISEN',
      rating: 4.3,
      year: 2020,
      episodeCount: 47,
      genres: <String>['Action', 'Supernatural', 'Fantasy'],
      synopsis: 'Yuji Itadori is a boy with tremendous physical strength, though he lives a completely ordinary high school life. One day, to save a classmate who has been attacked by curses, he eats the finger of Ryomen Sukuna,...',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx113415-LHBAeoZDIsnF.jpg',
      anilistId: 113415,
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
      currentEpisode: 5,
      minutesLeft: 12,
    ),
    const Anime(
      id: 'demon-slayer',
      title: 'Demon Slayer: Kimetsu no Yaiba',
      rating: 4.3,
      year: 2019,
      episodeCount: 63,
      genres: <String>['Action', 'Fantasy', 'Supernatural'],
      synopsis: 'After a demon attack leaves his family slain and his sister cursed, Tanjiro embarks upon a perilous journey to find a cure and avenge those he\'s lost.',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx101922-WBsBl0ClmgYL.jpg',
      anilistId: 101922,
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
      currentEpisode: 5,
      minutesLeft: 12,
    ),
    const Anime(
      id: 'chainsaw-man',
      title: 'Chainsaw Man',
      rating: 4.3,
      year: 2022,
      episodeCount: 12,
      genres: <String>['Action', 'Fantasy', 'Horror'],
      synopsis: 'Denji has a simple dream—to live a happy and peaceful life, spending time with a girl he likes. This is a far cry from reality, however, as Denji is forced by the yakuza into killing devils in order to pay off his...',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx127230-DdP4vAdssLoz.png',
      anilistId: 127230,
      gradient: <Color>[Color(0xFF0B4D5C), Color(0xFF0A0A13)],
      currentEpisode: 2,
      minutesLeft: 18,
    ),
    const Anime(
      id: 'one-piece',
      title: 'One Piece',
      rating: 4.4,
      year: 1999,
      episodeCount: 1180,
      genres: <String>['Action', 'Adventure', 'Comedy'],
      synopsis: 'Years ago, the fearsome Pirate King, Gol D. Roger was executed leaving a huge pile of treasure and the famous "One Piece" behind. Whoever claims the "One Piece" will be named the new King of the Pirates.  Monkey D....',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx21-ELSYx3yMPcKM.jpg',
      anilistId: 21,
      gradient: <Color>[Color(0xFF3A6EA5), Color(0xFF12233D)],
      currentEpisode: 10,
      minutesLeft: 4,
    ),
    const Anime(
      id: 'mob-psycho-100',
      title: 'Mob Psycho 100',
      rating: 4.2,
      year: 2016,
      episodeCount: 37,
      genres: <String>['Action', 'Comedy', 'Supernatural'],
      synopsis: 'Shigeo Kageyama, a.k.a. "Mob," is a boy who has trouble expressing himself, but who happens to be a powerful esper. Mob is determined to live a normal life and keeps his ESP suppressed, but when his emotions surge to...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/vR7hwaGQ0ySRoq1WobiNRaPs4WO.jpg',
      anilistId: 21507,
      gradient: <Color>[Color(0xFF4D4D5C), Color(0xFF14141C)],
    ),
    const Anime(
      id: 'frieren',
      title: 'Frieren: Beyond Journey\'s End',
      rating: 4.4,
      year: 2023,
      episodeCount: 28,
      genres: <String>['Adventure', 'Drama', 'Fantasy'],
      synopsis: 'After the party of heroes defeated the Demon King, they restored peace to the land and returned to lives of solitude. Generations pass, and the elven mage Frieren comes face to face with humanity\'s mortality. She...',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx154587-qQTzQnEJJ3oB.jpg',
      anilistId: 154587,
      gradient: <Color>[Color(0xFF7A5A8C), Color(0xFF241A2E)],
    ),
    const Anime(
      id: 'attack-on-titan',
      title: 'Attack on Titan',
      rating: 4.3,
      year: 2013,
      episodeCount: 87,
      genres: <String>['Action', 'Drama', 'Fantasy'],
      synopsis: '100 years ago, the last remnants of humanity were forced to retreat behind the towering walls of a fortified city to escape the massive, man-eating Titans that roamed the land outside their fortress. Only the members...',
      posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx16498-buvcRTBx4NSm.jpg',
      anilistId: 16498,
      gradient: <Color>[Color(0xFF2E1A4D), Color(0xFF0E0A18)],
    ),
    const Anime(
      id: 'vinland-saga',
      title: 'Vinland Saga',
      rating: 4.2,
      year: 2019,
      episodeCount: 48,
      genres: <String>['Action', 'Adventure', 'Drama'],
      synopsis: 'For a thousand years, the Vikings have made quite a name and reputation for themselves as the strongest families with a thirst for violence. Thorfinn, the son of one of the Vikings\' greatest warriors, spends his...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/vUHlpA5c1NXkds59reY3HMb4Abs.jpg',
      anilistId: 101348,
      gradient: <Color>[Color(0xFF5C3A1A), Color(0xFF1C120A)],
    ),
    const Anime(
      id: 'dark-summoner',
      title: 'I\'m Dating a Dark Summoner',
      rating: 4.3,
      year: 2026,
      episodeCount: 12,
      genres: <String>['Comedy', 'Fantasy', 'Romance'],
      synopsis: 'Amona, a dark summoner and demi-human girl who\'s too weak to resist her desires, and Roni, an overly serious priest! Roni welcomes Amona as a new member to his adventuring party. Everyone expected the two would clash...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/xD8bCXGlwC98mFq8mDyB15grUts.jpg',
      anilistId: 208025,
      gradient: <Color>[Color(0xFF1F4D3A), Color(0xFF0A1A12)],
      nextEpisode: 9,
      nextEpisodeIn: '6d 20h',
      nextEpisodeAt: 'Nov 29 at 22:05',
    ),
    const Anime(
      id: 'naruto',
      title: 'Naruto',
      rating: 4.2,
      year: 2002,
      episodeCount: 220,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Naruto Uzumaki, a mischievous adolescent ninja, struggles as he searches for recognition and dreams of becoming the Hokage, the village\'s leader and strongest ninja.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/xppeysfvDKVx775MFuH8Z9BlpMk.jpg',
      anilistId: 20,
      gradient: <Color>[Color(0xFF6B1F2A), Color(0xFF1F0A0E)],
    ),
    const Anime(
      id: 'bleach',
      title: 'Bleach',
      rating: 4.2,
      year: 2004,
      episodeCount: 366,
      genres: <String>['Action', 'Adventure', 'Supernatural'],
      synopsis: 'For as long as he can remember, Ichigo Kurosaki has been able to see ghosts. But when he meets Rukia, a Soul Reaper who battles evil spirits known as Hollows, he finds his life is changed forever. Now, with a...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/2EewmxXe72ogD0EaWM8gqa0ccIw.jpg',
      anilistId: 269,
      gradient: <Color>[Color(0xFF1A3A6B), Color(0xFF0A1220)],
    ),
    const Anime(
      id: 'dragon-ball-z',
      title: 'Dragon Ball Z',
      rating: 4.2,
      year: 1989,
      episodeCount: 291,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Now happily married and with a son, martial arts champion Goku must defend Earth from a series of extraterrestrial invaders bent on destruction.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/oQ5CnVj3TRifXl2bIOri6H6rfNe.jpg',
      anilistId: 813,
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    ),
    const Anime(
      id: 'death-note',
      title: 'Death Note',
      rating: 4.3,
      year: 2006,
      episodeCount: 37,
      genres: <String>['Thriller', 'Supernatural', 'Mystery'],
      synopsis: 'Light Yagami is an ace student with great prospects—and he’s bored out of his mind. But all that changes when he finds the Death Note, a notebook dropped by a rogue Shinigami death god. Any human whose name is...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/tCZFfYTIwrR7n94J6G14Y4hAFU6.jpg',
      anilistId: 1535,
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
    ),
    const Anime(
      id: 'fullmetal-alchemist-brotherhood',
      title: 'Fullmetal Alchemist: Brotherhood',
      rating: 4.4,
      year: 2009,
      episodeCount: 64,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Disregard for alchemy’s laws ripped half of Edward Elric’s limbs from his body and left his brother Alphonse’s soul clinging to a suit of armor. To restore what was lost, the brothers seek the Philosopher’s Stone....',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/5ZFUEOULaVml7pQuXxhpR2SmVUw.jpg',
      anilistId: 5114,
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
    ),
    const Anime(
      id: 'my-hero-academia',
      title: 'My Hero Academia',
      rating: 4.3,
      year: 2016,
      episodeCount: 138,
      genres: <String>['Action', 'Adventure', 'Superhero'],
      synopsis: 'Izuku has dreamt of being a hero all his life—a lofty goal for anyone, but especially challenging for a kid with no superpowers. That’s right, in a world where eighty percent of the population has some kind of...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/phuYuzqWW9ru8EA3HVjE9W2Rr3M.jpg',
      anilistId: 21459,
      gradient: <Color>[Color(0xFF0B4D5C), Color(0xFF0A0A13)],
    ),
    const Anime(
      id: 'hunter-x-hunter',
      title: 'Hunter x Hunter',
      rating: 4.3,
      year: 2011,
      episodeCount: 148,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Gon, a young boy who lives on Whale Island, dreams of becoming a Hunter like his father, who left when Gon was still young.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/i2EEr2uBvRlAwJ8d8zTG2Y19mIa.jpg',
      anilistId: 11061,
      gradient: <Color>[Color(0xFF3A6EA5), Color(0xFF12233D)],
    ),
    const Anime(
      id: 'tokyo-ghoul',
      title: 'Tokyo Ghoul',
      rating: 4.1,
      year: 2014,
      episodeCount: 48,
      genres: <String>['Action', 'Horror', 'Supernatural'],
      synopsis: 'Ken Kaneki, a bookworm college student, meets Rize, a girl his own age with whom he shares many interests.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/1m4RlC9BTCbyY549TOdVQ5NRPcR.jpg',
      anilistId: 20605,
      gradient: <Color>[Color(0xFF4D4D5C), Color(0xFF14141C)],
    ),
    const Anime(
      id: 'sword-art-online',
      title: 'Sword Art Online',
      rating: 4.1,
      year: 2012,
      episodeCount: 96,
      genres: <String>['Action', 'Adventure', 'Sci-Fi'],
      synopsis: 'In the near future, a Virtual Reality Massive Multiplayer Online Role-Playing Game (VRMMORPG) called Sword Art Online has been released where players control their avatars with their bodies using a piece of...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/9m8bFIXPg26taNrFSXGwEORVACD.jpg',
      anilistId: 11757,
      gradient: <Color>[Color(0xFF7A5A8C), Color(0xFF241A2E)],
    ),
    const Anime(
      id: 're-zero',
      title: 'Re:ZERO -Starting Life in Another World-',
      rating: 4.1,
      year: 2016,
      episodeCount: 50,
      genres: <String>['Action', 'Drama', 'Fantasy'],
      synopsis: 'Natsuki Subaru, an ordinary high school  student, is on his way home from the convenience store when he finds  himself transported to another world. As he\'s lost and confused in a new  world where he doesn\'t even...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/oHqYrPAsIiTD5m4DuxumV4er8BU.jpg',
      anilistId: 21355,
      gradient: <Color>[Color(0xFF2E1A4D), Color(0xFF0E0A18)],
    ),
    const Anime(
      id: 'cowboy-bebop',
      title: 'Cowboy Bebop',
      rating: 4.2,
      year: 1998,
      episodeCount: 26,
      genres: <String>['Action', 'Adventure', 'Sci-Fi'],
      synopsis: 'In 2071, roughly fifty years after an accident with a hyperspace gateway made the Earth almost uninhabitable, humanity has colonized most of the rocky planets and moons of the Solar System. Amid a rising crime rate,...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/xDiXDfZwC6XYC6fxHI1jl3A3Ill.jpg',
      anilistId: 1,
      gradient: <Color>[Color(0xFF5C3A1A), Color(0xFF1C120A)],
    ),
    const Anime(
      id: 'neon-genesis-evangelion',
      title: 'Neon Genesis Evangelion',
      rating: 4.3,
      year: 1995,
      episodeCount: 26,
      genres: <String>['Action', 'Drama', 'Sci-Fi'],
      synopsis: 'At the turn of the century, the Angels returned to Earth, seeking to wipe out humanity in an apocalyptic fury. Devastated, mankind\'s last remnants moved underground to wait for the day when the Angels would come back...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/y2ah9t0navXyIvoHg1uIbIHO3tt.jpg',
      anilistId: 30,
      gradient: <Color>[Color(0xFF1F4D3A), Color(0xFF0A1A12)],
    ),
    const Anime(
      id: 'code-geass',
      title: 'Code Geass: Lelouch of the Rebellion',
      rating: 4.2,
      year: 2006,
      episodeCount: 50,
      genres: <String>['Action', 'Drama', 'Sci-Fi'],
      synopsis: 'Japan has been invaded and conquered by the Britannian Empire. Japan is now known as Area 11 and its citizens known as Elevens. The Britannian Empire takes away Japan\'s autonomous power and imposes its rule through...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/1cFqtyKUbdo1IurdpkK4tDthUJO.jpg',
      anilistId: 1575,
      gradient: <Color>[Color(0xFF6B1F2A), Color(0xFF1F0A0E)],
    ),
    const Anime(
      id: 'steins-gate',
      title: 'Steins;Gate',
      rating: 4.2,
      year: 2011,
      episodeCount: 24,
      genres: <String>['Drama', 'Sci-Fi', 'Thriller'],
      synopsis: 'A group of friends have customized their microwave so that it can send text messages to the past. As they perform different experiments, an organization named SERN who has been doing their own research on time travel...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/96R4bV7dB8ramaWceNKsxvJgCUd.jpg',
      anilistId: 9253,
      gradient: <Color>[Color(0xFF1A3A6B), Color(0xFF0A1220)],
    ),
    const Anime(
      id: 'one-punch-man',
      title: 'One-Punch Man',
      rating: 4.2,
      year: 2015,
      episodeCount: 24,
      genres: <String>['Action', 'Comedy', 'Superhero'],
      synopsis: 'Saitama is a hero who only became a hero for fun. After three years of “special” training, though, he’s become so strong that he’s practically invincible. In fact, he’s too strong—even his mightiest opponents are...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/dT10AxJIXVvRwFAew4tt2RhzJrD.jpg',
      anilistId: 21087,
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    ),
    const Anime(
      id: 'haikyu',
      title: 'Haikyu!!',
      rating: 4.3,
      year: 2014,
      episodeCount: 85,
      genres: <String>['Comedy', 'Drama', 'Sports'],
      synopsis: 'Inspired by a small-statured pro volleyball player, Hinata creates a volleyball team in his last year of middle school. Unfortunately the team is matched up against the "King of the Court" Tobio Kageyama’s team in...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/8WEr48swcqe89Zsy5sdrGCASlIg.jpg',
      anilistId: 20464,
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
    ),
    const Anime(
      id: 'black-clover',
      title: 'Black Clover',
      rating: 4.3,
      year: 2017,
      episodeCount: 170,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Asta and Yuno are two orphans who want the same thing: to become the Wizard King. Locked in a friendly rivalry, they work hard towards their goal. While Yuno excels at magic, Asta has a problem uncommon in this...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/uZUtoVChBGhNj9OfrM2LYpwBm8E.jpg',
      anilistId: 97940,
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
    ),
    const Anime(
      id: 'fairy-tail',
      title: 'Fairy Tail',
      rating: 4.0,
      year: 2009,
      episodeCount: 328,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Lucy is a 17-year-old girl, who wants to be a full-fledged mage. One day when visiting Harujion Town, she meets Natsu, a young man who gets sick easily by any type of transportation. But Natsu isn\'t just any ordinary...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/AsfCVSHnFnUnbepLucvIB1N30Il.jpg',
      anilistId: 6702,
      gradient: <Color>[Color(0xFF0B4D5C), Color(0xFF0A0A13)],
    ),
    const Anime(
      id: 'gintama',
      title: 'Gintama',
      rating: 4.1,
      year: 2006,
      episodeCount: 367,
      genres: <String>['Action', 'Comedy', 'Sci-Fi'],
      synopsis: 'In a world where aliens have invaded Edo Period Japan, skyscrapers, trains and motor bikes have replaced the simple life of Earth inhabitants. One man however, still carries the soul of a samurai, Gintoki Sakata,...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/f7vK8pzZIqhyA8sYmBpWmp9Ae7.jpg',
      anilistId: 918,
      gradient: <Color>[Color(0xFF3A6EA5), Color(0xFF12233D)],
    ),
    const Anime(
      id: 'jojos-bizarre-adventure',
      title: 'JoJo\'s Bizarre Adventure',
      rating: 4.3,
      year: 2012,
      episodeCount: 190,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Follow the intergenerational feud between the Joestar Family and various forces of evil, the most prominent of which is Dio Brando and his followers.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/ogAWwbh3frWtiTyyXrZaVFtqCgp.jpg',
      anilistId: 14719,
      gradient: <Color>[Color(0xFF4D4D5C), Color(0xFF14141C)],
    ),
    const Anime(
      id: 'spy-x-family',
      title: 'SPY x FAMILY',
      rating: 4.2,
      year: 2022,
      episodeCount: 37,
      genres: <String>['Action', 'Comedy', 'Family'],
      synopsis: 'A spy, an assassin and a telepath come together to pose as a family, each for their own reasons, while hiding their true identities from each other.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/7NAvPYPAu7MeHwP8E9sn81PqsRh.jpg',
      anilistId: 140960,
      gradient: <Color>[Color(0xFF7A5A8C), Color(0xFF241A2E)],
    ),
    const Anime(
      id: 'blue-lock',
      title: 'BLUE LOCK',
      rating: 4.2,
      year: 2022,
      episodeCount: 38,
      genres: <String>['Action', 'Drama', 'Sports'],
      synopsis: 'High school soccer players from across Japan gather for a controversial project designed to create the best — and most egoistic — striker in the world.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/fcKH1NQzoTXiYO1OrhaFFwTKhBp.jpg',
      anilistId: 137822,
      gradient: <Color>[Color(0xFF2E1A4D), Color(0xFF0E0A18)],
    ),
    const Anime(
      id: 'dr-stone',
      title: 'Dr. STONE',
      rating: 4.2,
      year: 2019,
      episodeCount: 57,
      genres: <String>['Adventure', 'Comedy', 'Sci-Fi'],
      synopsis: 'One fateful day, all of humanity was petrified by a blinding flash of light. After several millennia, high schooler Taiju awakens and finds himself lost in a world of statues. However, he’s not alone! His...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/xbZQ3fDl0y5mt0ARwfeyrgQ4JTw.jpg',
      anilistId: 105333,
      gradient: <Color>[Color(0xFF5C3A1A), Color(0xFF1C120A)],
    ),
    const Anime(
      id: 'fire-force',
      title: 'Fire Force',
      rating: 4.2,
      year: 2019,
      episodeCount: 48,
      genres: <String>['Action', 'Fantasy', 'Supernatural'],
      synopsis: 'Year 198 of the Solar Era in Tokyo, special fire brigades are fighting against a phenomenon called spontaneous human combustion where humans beings are turned into living infernos called "Infernals". While the...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/96jrp8XIEPKC7xHhbkpWLD15oYW.jpg',
      anilistId: 105310,
      gradient: <Color>[Color(0xFF1F4D3A), Color(0xFF0A1A12)],
    ),
    const Anime(
      id: 'reincarnated-as-a-slime',
      title: 'That Time I Got Reincarnated as a Slime',
      rating: 4.2,
      year: 2018,
      episodeCount: 48,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'Corporate worker Mikami Satoru is stabbed by a random killer, and is reborn to an alternate world. But he turns out to be reborn a slime! Thrown into this new world with the name Rimuru, he begins his quest to create...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/pzujcdPAoH361NObVrtbA7zACE7.jpg',
      anilistId: 101280,
      gradient: <Color>[Color(0xFF6B1F2A), Color(0xFF1F0A0E)],
    ),
    const Anime(
      id: 'overlord',
      title: 'Overlord',
      rating: 4.2,
      year: 2015,
      episodeCount: 52,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'In the year 2138, virtual reality gaming is booming. Yggdrasil, a popular online game is quietly shut down one day. However, one player named Momonga decides to not log out. Momonga is then transformed into the image...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/K8ZUjxaj9F0t3AwJDz8ypzBynM.jpg',
      anilistId: 20832,
      gradient: <Color>[Color(0xFF1A3A6B), Color(0xFF0A1220)],
    ),
    const Anime(
      id: 'mushoku-tensei',
      title: 'Mushoku Tensei: Jobless Reincarnation',
      rating: 4.2,
      year: 2021,
      episodeCount: 48,
      genres: <String>['Action', 'Adventure', 'Fantasy'],
      synopsis: 'When a 34-year-old underachiever gets run over by a truck, his story doesn\'t end there. Reincarnated in a new world as an infant, Rudy will seize every opportunity to live the life he\'s always wanted. Armed with new...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/lDS7WuWrq6i1XC1AaKlf9qvJBVi.jpg',
      anilistId: 108465,
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    ),
    const Anime(
      id: 'made-in-abyss',
      title: 'Made in Abyss',
      rating: 4.2,
      year: 2017,
      episodeCount: 26,
      genres: <String>['Adventure', 'Drama', 'Fantasy'],
      synopsis: 'Located in the center of a remote island, the Abyss is the last unexplored region, a huge and treacherous fathomless hole inhabited by strange creatures where only the bravest adventurers descend in search of ancient...',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/n30CBH4BoN5Z34tCpOWIPGJYOaS.jpg',
      anilistId: 97986,
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
    ),
    const Anime(
      id: 'violet-evergarden',
      title: 'Violet Evergarden',
      rating: 4.3,
      year: 2018,
      episodeCount: 13,
      genres: <String>['Drama', 'Fantasy', 'Romance'],
      synopsis: 'The war is over, and Violet Evergarden needs a job. Scarred and emotionless, she takes a job as a letter writer to understand herself and her past.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/61EwFPqc0r1uJo6la49J55F8bQ8.jpg',
      anilistId: 21827,
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
    ),
  ];
}

/// Bundled anime-movie fallback for the Home MOVIES row (0.2.9).
/// Used when the live AniList movie query fails or returns empty
/// (offline / rate limit) — the row is never blank. Every entry is
/// one "episode", so Detail/player treat it like any single-episode
/// title and play through the existing resolver path. Poster URLs
/// are TMDB w500, each verified to return 200 — except Violet
/// Evergarden: The Movie, whose TMDB poster could not be verified,
/// so it has no posterUrl and shows the gradient art. anilistId is
/// set only where known for certain; the rest resolve by title at
/// play time (same as catalogue titles without a stored id).
List<Anime> mockMovies() {
  return <Anime>[
    const Anime(
      id: 'movie-your-name',
      title: 'Your Name',
      rating: 4.4,
      year: 2016,
      episodeCount: 1,
      genres: <String>['Drama', 'Romance', 'Supernatural'],
      synopsis: 'Two teenagers who swap bodies across time and distance race to meet before a comet changes everything.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/q719jXXEzOoYaps6babgKnONONX.jpg',
      anilistId: 21519,
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    ),
    const Anime(
      id: 'movie-spirited-away',
      title: 'Spirited Away',
      rating: 4.4,
      year: 2001,
      episodeCount: 1,
      genres: <String>['Adventure', 'Fantasy'],
      synopsis: 'A girl wanders into a bathhouse for spirits and must work there to free her transformed parents.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/39wmItIWsg5sZMyRUHLkWBcuVCM.jpg',
      anilistId: 199,
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
    ),
    const Anime(
      id: 'movie-mugen-train',
      title: 'Demon Slayer: Mugen Train',
      rating: 4.2,
      year: 2020,
      episodeCount: 1,
      genres: <String>['Action', 'Fantasy'],
      synopsis: 'Tanjiro boards the Infinity Train with the Flame Hashira to stop a demon haunting its passengers.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/h8Rb9gBr48ODIwYUttZNYeMWeUU.jpg',
      gradient: <Color>[Color(0xFF4D1A1A), Color(0xFF120E24)],
    ),
    const Anime(
      id: 'movie-jujutsu-kaisen-0',
      title: 'Jujutsu Kaisen 0',
      rating: 4.1,
      year: 2021,
      episodeCount: 1,
      genres: <String>['Action', 'Fantasy'],
      synopsis: 'Yuta Okkotsu, haunted by a powerful cursed spirit, joins Jujutsu High to learn to control it.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/3pTwMUEavTzVOh6yLN0aEwR7uSy.jpg',
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
    ),
    const Anime(
      id: 'movie-a-silent-voice',
      title: 'A Silent Voice',
      rating: 4.4,
      year: 2016,
      episodeCount: 1,
      genres: <String>['Drama', 'Romance'],
      synopsis: 'A former bully seeks redemption years later by reconnecting with the deaf girl he once tormented.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/tuFaWiqX0TXoWu7DGNcmX3UW7sT.jpg',
      anilistId: 20934,
      gradient: <Color>[Color(0xFF3B2A6B), Color(0xFF120E24)],
    ),
    const Anime(
      id: 'movie-weathering-with-you',
      title: 'Weathering With You',
      rating: 4.0,
      year: 2019,
      episodeCount: 1,
      genres: <String>['Drama', 'Fantasy', 'Romance'],
      synopsis: 'A runaway teen in rainy Tokyo meets a girl who can clear the sky — at a price.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/qgrk7r1fV4IjuoeiGS5HOhXNdLJ.jpg',
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
    ),
    const Anime(
      id: 'movie-suzume',
      title: 'Suzume',
      rating: 4.0,
      year: 2022,
      episodeCount: 1,
      genres: <String>['Adventure', 'Drama', 'Fantasy'],
      synopsis: 'A 17-year-old girl helps a mysterious young man close doors unleashing disasters across Japan.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/yStW1TXF5s7Tbtu9KjIZEaWl6HL.jpg',
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
    ),
    const Anime(
      id: 'movie-boy-and-the-heron',
      title: 'The Boy and the Heron',
      rating: 3.8,
      year: 2023,
      episodeCount: 1,
      genres: <String>['Adventure', 'Drama', 'Fantasy'],
      synopsis: 'During the war, a boy follows a talking grey heron into a strange world to find his mother.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/4GKye5dR4uJyYbcyTveSue1gATD.jpg',
      gradient: <Color>[Color(0xFF0F3A4D), Color(0xFF0A1420)],
    ),
    const Anime(
      id: 'movie-violet-evergarden',
      title: 'Violet Evergarden: The Movie',
      rating: 4.2,
      year: 2020,
      episodeCount: 1,
      genres: <String>['Drama', 'Fantasy', 'Romance'],
      synopsis: 'Violet keeps searching for the meaning of the Major’s last words when a letter request stirs her past.',
      gradient: <Color>[Color(0xFF2A2A3A), Color(0xFF101018)],
    ),
    const Anime(
      id: 'movie-one-piece-film-red',
      title: 'One Piece Film: Red',
      rating: 3.8,
      year: 2022,
      episodeCount: 1,
      genres: <String>['Action', 'Adventure', 'Music'],
      synopsis: 'Luffy’s crew attends pop superstar Uta’s first concert — and her song threatens to trap the world in a dream.',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/8ibfhe4P7rhmn3lrPhOZzIJHA2B.jpg',
      gradient: <Color>[Color(0xFF4D1A1A), Color(0xFF120E24)],
    ),
  ];
}

List<Episode> mockEpisodes(Anime anime) {
  const List<String> titles = <String>[
    'Infiltration Protocol',
    'Ghost in the Network',
    'Neon Blackout',
    'The Codex Awakens',
    'Crimson Oath',
    'Silent Exchange',
    'Blood Moon Rising',
    'The Last Gate',
  ];
  const List<String> durations = <String>[
    '23:12',
    '24:05',
    '22:58',
    '24:31',
    '23:47',
    '24:02',
    '23:19',
    '24:44',
  ];
  const List<String> synopses = <String>[
    'The crew sets sail for the cloud seas, but a storm on the horizon '
        'has other plans.',
    'A quiet exchange in the neon district reveals a secret no one was '
        'ready to hear.',
    'The gate opens at midnight, and the warden must choose who walks '
        'through it.',
    'Old debts come due as the rebellion reaches the capital walls.',
    'A phantom thief strikes at dawn, and the treasure is not what '
        'anyone expected.',
    'Two rivals share one room for the night. Neither one sleeps.',
  ];
  final int count = anime.episodeCount;
  return List<Episode>.generate(count, (int i) {
    final int n = i + 1;
    return Episode(
      number: n,
      title: titles[i % titles.length],
      duration: durations[i % durations.length],
      synopsis: synopses[i % synopses.length],
      airDate: _mockAirDate(n),
      // Dubbed tracks lag behind: every 3rd episode is sub-only in M1.
      hasDub: n % 3 != 0,
    );
  });
}

/// Weekly air date starting Sep 5, 2026 (M1 mock): "Oct 4, 2026".
String _mockAirDate(int episodeNumber) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final DateTime d = DateTime(
    2026,
    9,
    5,
  ).add(Duration(days: (episodeNumber - 1) * 7));
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Default Sources order: Miruro, AniKoto, AniSuge, AniKage,
/// AniPM, Anime-Sama. The user can reorder in Settings > Sources; this is
/// only the default. (No ranking by episode counts — the 01:41
/// "1 2 3" meant the episode NUMBER grid, not a sources ranking.)
/// 0.2.23: ReAnime (flixcloud token API 410s — dead) and AniZone
/// are removed. 0.2.24: AniSuge (anisuge.tv, AnimeWave clone —
/// same backend as AniKoto) and AniKage (anikage.cc, SvelteKit
/// JSON API) join as 3rd and 4th.
/// 0.2.25: AnimeKai (animekai.ro) is REMOVED — its megavid
/// streams never played on the phone, even after the 0.2.24
/// browser-equivalent header fix (user order, 2026-11-25).
/// AniPM (anipm.pk) joins LAST as a WebView-embed source — its
/// streams live inside a Cloudflare-gated settlar embed (the
/// session API returns only an embedUrl, no stream URL), so it
/// plays in a fullscreen WebView with the site's own controls,
/// never through mpv. Anime-Sama (anime-sama.to) joins after
/// AniPM — French site, VOSTFR (Japanese audio + French
/// hardsubs) / VF (French dub) via Vidmoly HLS; no English
/// audio or subtitles on this source.
List<ProviderSource> defaultSources() {
  return const <ProviderSource>[
    ProviderSource(
      name: 'Miruro',
      tagline: '1080p • Sub • Fast',
      enabled: true,
      preferred: true,
    ),
    ProviderSource(
      name: 'AniKoto',
      tagline: '1080p • Sub • Stable',
      enabled: true,
    ),
    ProviderSource(name: 'AniSuge', tagline: '1080p • Sub/Dub', enabled: true),
    ProviderSource(name: 'AniKage', tagline: '1080p • Sub/Dub', enabled: true),
    ProviderSource(name: 'AniPM', tagline: 'WebView • Sub/Dub', enabled: true),
    ProviderSource(
      name: 'Anime-Sama',
      tagline: 'French • VOSTFR/VF',
      enabled: true,
    ),
  ];
}
