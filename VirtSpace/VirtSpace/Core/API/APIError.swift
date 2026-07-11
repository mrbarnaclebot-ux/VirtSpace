//
//  APIError.swift
//  VirtSpace
//
//  Typed network errors surfaced to the UI. Every network action maps failures
//  into one of these cases so nothing is silently swallowed.
//

import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case quota
    case server(Int, String?)
    case decoding(Error)
    case network(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Not authorized. Check the dev-auth token in Secrets."
        case .quota:
            return "Daily scan quota or credit budget reached. Try again later."
        case .server(let code, let message):
            if let message, !message.isEmpty {
                return "Server error (\(code)): \(message)"
            }
            return "Server error (\(code)). Please try again."
        case .decoding:
            return "Couldn't read the server's response."
        case .network(let underlying):
            return underlying.localizedDescription
        case .invalidResponse:
            return "Unexpected response from the server."
        }
    }
}
