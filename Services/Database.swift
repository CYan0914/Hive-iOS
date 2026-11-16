import Foundation
import SQLite3

/// SQLite copies the bound buffer on the spot. Without this the pointer would
/// have to outlive the statement, which no call site here guarantees.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)
}

struct SQLRow {
    let stmt: OpaquePointer

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: pointer)
    }

    func optionalString(_ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return string(index)
    }

    func data(_ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: pointer, count: count)
    }
}

enum DatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case exec(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "打开数据库失败：\(message)"
        case .prepare(let message): return "SQL 准备失败：\(message)"
        case .step(let message): return "SQL 执行失败：\(message)"
        case .exec(let message): return "SQL 错误：\(message)"
        }
    }
}

/// A thin, dependency-free SQLite wrapper.
///
/// GRDB would do more, but every dependency is one more thing that can break a
/// CI compile on a machine that has no Xcode. The surface used here is small
/// enough that the C API is easier to reason about than to import.
final class Database {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    let path: String

    init(path: String) throws {
        self.path = path
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            if let database { sqlite3_close(database) }
            throw DatabaseError.open(message)
        }
        handle = database
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    private func message() -> String {
        guard let handle else { return "数据库已关闭" }
        return String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.exec("数据库已关闭") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let text = errorPointer.map { String(cString: $0) } ?? "unknown"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw DatabaseError.exec(text)
        }
    }

    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw DatabaseError.step(message())
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func query<T>(
        _ sql: String,
        _ values: [SQLValue] = [],
        map: (SQLRow) throws -> T
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                rows.append(try map(SQLRow(stmt: statement)))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.step(message())
            }
        }
        return rows
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        guard let handle else { throw DatabaseError.prepare("数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError.prepare(message())
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .int(let number):
                sqlite3_bind_int64(statement, index, Int64(number))
            case .double(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .blob(let data):
                if data.isEmpty {
                    sqlite3_bind_blob(statement, index, "", 0, sqliteTransient)
                } else {
                    data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                    }
                }
            }
        }
        return statement
    }
}
