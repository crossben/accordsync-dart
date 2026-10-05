import 'errors.dart';

/// The largest counter value; one more rolls the clock into the next millisecond.
const int maxCounter = 99999;

/// The largest integer JavaScript represents exactly: clocks and counts stay within it.
const int maxSafeInteger = 9007199254740991;

final RegExp _node = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final RegExp _encoded = RegExp(r'^(\d{1,16}):(\d{5}):([A-Za-z0-9_-]{1,64})$');

/// Hybrid logical clock: physical time + logical counter + node id.
///
/// Orders events consistently even when device clocks are wrong; [compareTo] is a total order, since
/// the node id breaks ties. Port of `hlc.ts`.
final class Hlc implements Comparable<Hlc> {
  const Hlc(this.wall, this.counter, this.node);

  /// The clock a node starts from.
  factory Hlc.initial(String node) {
    assertNode(node);
    return Hlc(0, 0, node);
  }

  /// Parses `wall:counter:node` (counter zero-padded to 5 digits).
  factory Hlc.decode(String s) {
    final m = _encoded.firstMatch(s);
    if (m == null) throw AccordException('malformed hlc "$s"');
    final wall = int.parse(m.group(1)!);
    if (wall > maxSafeInteger) throw AccordException('hlc wall out of range in "$s"');
    return Hlc(wall, int.parse(m.group(2)!), m.group(3)!);
  }

  /// Milliseconds since the Unix epoch, as seen by the node (possibly pushed forward by others).
  final int wall;

  /// Disambiguates events within the same [wall] millisecond.
  final int counter;

  /// The device or server that produced the clock.
  final String node;

  String encode() => '$wall:${counter.toString().padLeft(5, '0')}:$node';

  /// The clock for a new local event at physical time [now].
  Hlc tick(int now) => now > wall ? Hlc(now, 0, node) : _after(wall, counter, node);

  /// The clock after observing [remote] at physical time [now]. Refuses a remote clock more than
  /// [maxSkewMs] ahead of [now], so one phone with a wrong date cannot win every merge forever.
  Hlc receive(Hlc remote, int now, int maxSkewMs) {
    if (remote.wall - now > maxSkewMs) {
      throw ClockSkewException(
        'clock of ${remote.node} is ${remote.wall - now} ms ahead (limit $maxSkewMs ms)',
      );
    }
    final w = [wall, remote.wall, now].reduce((a, b) => a > b ? a : b);
    if (w == wall && w == remote.wall) {
      return _after(w, counter > remote.counter ? counter : remote.counter, node);
    }
    if (w == wall) return _after(w, counter, node);
    if (w == remote.wall) return _after(w, remote.counter, node);
    return Hlc(w, 0, node);
  }

  @override
  int compareTo(Hlc other) {
    if (wall != other.wall) return wall < other.wall ? -1 : 1;
    if (counter != other.counter) return counter < other.counter ? -1 : 1;
    return node.compareTo(other.node).sign;
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.wall == wall && other.counter == counter && other.node == node;

  @override
  int get hashCode => Object.hash(wall, counter, node);

  @override
  String toString() => encode();
}

/// Throws unless [node] is a valid node (device) id: `[A-Za-z0-9_-]{1,64}`.
void assertNode(String node) {
  if (!_node.hasMatch(node)) {
    throw AccordException('node id must match ${_node.pattern}, got "$node"');
  }
}

/// The smallest clock after (wall, counter): a full counter rolls into the next millisecond.
Hlc _after(int wall, int counter, String node) =>
    counter >= maxCounter ? Hlc(wall + 1, 0, node) : Hlc(wall, counter + 1, node);
