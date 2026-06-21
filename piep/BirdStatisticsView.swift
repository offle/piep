import Charts
import MapKit
import SwiftUI

struct BirdSpeciesStatisticsView: View {
    let species: BirdSpecies
    @State private var calendarMonth = Date()

    var body: some View {
        List {
            Section("Überblick") {
                LabeledContent("Fundtage", value: "\(uniqueDays.count)")
                LabeledContent("Sessions", value: "\(sessions.count)")
                LabeledContent("Treffer", value: "\(totalDetectionCount)")
                if let first = observations.map(\.firstDetectedAt).min() {
                    LabeledContent("Erstfund", value: first.formatted(date: .abbreviated, time: .omitted))
                }
            }

            Section("Kalender") {
                HStack {
                    Button { shiftCalendarMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    Spacer()
                    Text(calendarMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.headline)
                    Spacer()
                    Button { shiftCalendarMonth(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)

                calendarGrid
            }

            Section("Entwicklung der letzten 12 Monate") {
                Chart(monthlyCounts) { item in
                    BarMark(
                        x: .value("Monat", item.month, unit: .month),
                        y: .value("Fundtage", item.count)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 190)
            }

            Section("Tageszeit") {
                Chart(hourlyCounts) { item in
                    BarMark(
                        x: .value("Stunde", item.hour),
                        y: .value("Sessions", item.count)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23])
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 190)
            }

            if !locations.isEmpty {
                Section("Fundorte") {
                    Map(initialPosition: .automatic) {
                        ForEach(locations) { location in
                            Marker(location.title, coordinate: location.coordinate)
                        }
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .navigationTitle("Statistik")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            calendarMonth = observations.map(\.firstDetectedAt).max() ?? Date()
        }
    }

    private var calendarGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let days = calendarDays
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Calendar.current.veryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    let hasFinding = uniqueDays.contains(Calendar.current.startOfDay(for: day))
                    Text(day.formatted(.dateTime.day()))
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            hasFinding ? Color.accentColor.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .overlay {
                            if hasFinding {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            }
                        }
                } else {
                    Color.clear.frame(height: 28)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var observations: [SessionSpeciesObservation] {
        species.relevantObservations.filter { $0.session?.isDeleted == false }
    }

    private var sessions: [BirdSession] {
        var seen = Set<UUID>()
        return observations.compactMap(\.session).filter { seen.insert($0.id).inserted }
    }

    private var uniqueDays: Set<Date> {
        Set(sessions.map { Calendar.current.startOfDay(for: $0.startedAt) })
    }

    private var totalDetectionCount: Int {
        observations.reduce(0) { $0 + $1.detectionCount }
    }

    private var monthlyCounts: [MonthCount] {
        let calendar = Calendar.current
        let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return (0..<12).reversed().compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: -offset, to: currentMonth),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: month)
            else { return nil }
            return MonthCount(
                month: month,
                count: uniqueDays.filter { $0 >= month && $0 < nextMonth }.count
            )
        }
    }

    private var hourlyCounts: [HourCount] {
        let grouped = Dictionary(grouping: sessions) { Calendar.current.component(.hour, from: $0.startedAt) }
        return (0..<24).map { HourCount(hour: $0, count: grouped[$0]?.count ?? 0) }
    }

    private var locations: [SpeciesLocation] {
        sessions.compactMap { session in
            guard let latitude = session.latitude, let longitude = session.longitude else { return nil }
            return SpeciesLocation(
                id: session.id,
                title: session.locationName ?? session.startedAt.formatted(date: .abbreviated, time: .shortened),
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
    }

    private var calendarDays: [Date?] {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: calendarMonth)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
        else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + dayRange.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: monthStart)
        }.map(Optional.some)
    }

    private func shiftCalendarMonth(_ delta: Int) {
        calendarMonth = Calendar.current.date(byAdding: .month, value: delta, to: calendarMonth) ?? calendarMonth
    }
}

private struct MonthCount: Identifiable {
    var id: Date { month }
    let month: Date
    let count: Int
}

private struct HourCount: Identifiable {
    var id: Int { hour }
    let hour: Int
    let count: Int
}

private struct SpeciesLocation: Identifiable {
    let id: UUID
    let title: String
    let coordinate: CLLocationCoordinate2D
}
