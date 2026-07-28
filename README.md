[![pub package](https://img.shields.io/pub/v/dolphinsr.svg)](https://pub.dev/packages/dolphinsr)
[![CI](https://github.com/banool/dolphinsr_dart/actions/workflows/ci.yml/badge.svg)](https://github.com/banool/dolphinsr_dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# dolphinsr

A spaced-repetition scheduling algorithm for Dart. Use it to build [flashcard](https://en.wikipedia.org/wiki/Flashcard) and review systems — for Flutter, the web, or the server — that decide which card to show next and when.

`dolphinsr` began as [yodaiken's](https://github.com/yodaiken/dolphinsr) JavaScript spaced-repetition library and was ported to Dart by [JobiJoba](https://github.com/JobiJoba/dolphhinsr_dart). This fork picks up that work — published to pub.dev under the shorter name `dolphinsr` — with the correctness and performance fixes described in the [changelog](CHANGELOG.md). It is maintained on a best-effort basis, and issues and pull requests are welcome.

## Algorithm

DolphinSR implements [spaced repetition](https://en.wikipedia.org/wiki/Spaced_repetition) in Dart. Specifically, it uses [Anki's modifications](https://docs.ankiweb.net/studying.html) to the SM-2 algorithm, including:

- an initial mode for learning new cards
- a mode for re-learning cards after forgetting them
- reducing the number of self-assigned ratings from 6 to 4
- factoring lateness into card scheduling
- Anki's default configuration options

While DolphinSR is intentionally very similar to Anki's algorithm, it does deviate in a few ways:

- improved support for adding reviews out of order (for example, due to network latency)
- very different internal data structures (DolphinSR is largely written in a functional style to make testing and debugging easier, and does not rely on storing computed data or any SQL database)
- only one kind of card

## Installation

```sh
dart pub add dolphinsr
```

Or add it to your `pubspec.yaml` manually:

```yaml
dependencies:
  dolphinsr: ^4.0.0
```

## Quick start

```dart
import 'package:dolphinsr/dolphinsr.dart';

void main() {
  final dolphin = DolphinSR();

  // Register your cards. Each master has fields and one or more
  // combinations describing which fields are the front and which are the
  // back (here, both directions of a two-sided card).
  dolphin.addMasters([
    Master(id: '1', fields: ['คน', 'person'], combinations: [
      Combination(front: [0], back: [1]),
      Combination(front: [1], back: [0]),
    ]),
  ]);

  // A summary of how many cards are due / later / learning / overdue.
  final stats = dolphin.summary();
  print('${stats.due}-${stats.later}-${stats.learning}-${stats.overdue}');

  // Pull the next card to show, present it, then record how it went.
  final card = dolphin.nextCard()!;
  print('${card.front} -> ${card.back}');

  dolphin.addReviews([
    Review(
      master: card.master,
      combination: card.combination,
      ts: DateTime.now(),
      rating: Rating.Good, // Again, Hard, Good, or Easy
    ),
  ]);
}
```

See [example/main.dart](https://github.com/banool/dolphinsr_dart/blob/master/example/main.dart) for a fuller run through a review session.

## License

[MIT](LICENSE). Copyright (c) 2019 Baziret Johann and (c) 2026 Daniel Porteous.
