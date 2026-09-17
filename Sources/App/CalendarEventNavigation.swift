import Foundation

enum CalendarEventNavigation {
	enum Destination: Equatable { case native, provider, unavailable, superseded }

	@MainActor
	static func destination(
		stored: JournalCalendarEvent,
		resolved: JournalCalendarEvent?,
		preferredApp: PreferredCalendarApp,
		openURL: (URL) async -> Bool,
		isCurrent: () -> Bool
	) async -> Destination {
		guard !Task.isCancelled, isCurrent() else { return .superseded }
		guard let resolved, CalendarOccurrenceIdentity.uniqueMatch(for: stored, among: [resolved]) != nil else {
			return .unavailable
		}
		guard preferredApp == .google, !stored.isRecurring, !resolved.isRecurring,
			stored.occurrenceDate == nil, resolved.occurrenceDate == nil,
			let url = resolved.providerURL
		else { return .native }
		let opened = await openURL(url)
		guard !Task.isCancelled, isCurrent() else { return .superseded }
		return opened ? .provider : .native
	}
}
