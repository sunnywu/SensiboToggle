# SensiboToggle iOS App

SensiboToggle is an iOS application that provides a user-friendly interface to control your Sensibo air conditioning units. The app allows users to turn devices on/off, adjust temperature settings, and manage multiple AC units from a single location.

## Project Overview and Purpose

The SensiboToggle app serves as a mobile interface for controlling Sensibo-enabled air conditioning devices. It connects to the Sensibo API to retrieve device status and send control commands, providing an optimized user experience with features like optimistic UI updates and rate-limiting handling.

## Key Features and Optimizations

### Core Features
- **Device Management**: View and control multiple air conditioning units
- **On/Off Toggle**: Instantly turn devices on or off
- **Temperature Control**: Adjust temperature settings for each device
- **Optimistic UI Updates**: Immediate UI response with automatic rollback on API failure

### Performance Optimizations
1. **Optimistic Updates**: UI reflects changes immediately without waiting for API confirmation
2. **Error Handling**: Automatic rollback of UI changes when API calls fail
3. **Rate Limiting Support**: Built-in retry logic with exponential backoff for the Sensibo API
4. **Connection Warmup**: Pre-warms connections to improve perceived latency
5. **Mock Mode**: Development testing with mock data

### Technical Implementation
- SwiftUI-based modern UI framework
- Asynchronous programming using async/await
- Comprehensive unit and UI testing
- Type-safe API integration with Sensibo platform

## Local Configuration

The real Sensibo API key is read from `config/local.config.json`. That file is ignored by Git and must not be committed.

To run against the real Sensibo API, create your private config from the example:

```bash
cp config/local.config.example.json config/local.config.json
```

Then edit `config/local.config.json` and set your own API key.

To run with mock data, either keep `mockMode` set to `true` or run the app with `SENSIBO_MOCK=1`.

## How to Build and Run in Xcode Simulator (iPhone 17)

1. Open the project in Xcode:
   ```
   open SensiboToggle.xcodeproj
   ```

2. Select the iPhone 17 simulator as your target device

3. Build and run the application using:
   - Xcode menu: Product → Run (or press Cmd+R)
   - Or click the "Play" button in the toolbar

4. The app will launch in the simulator. Use `SENSIBO_MOCK=1` for mock data, or provide `config/local.config.json` for live API access.

## API Key Usage Instructions

Do not put real Sensibo API keys in source files, tests, README examples, or committed JSON files. Keep the live key only in `config/local.config.json` or provide it through the `SENSIBO_LIVE_KEY` environment variable for tests.

## Testing Information

### Unit Tests
The project includes comprehensive unit tests covering:
- API client behavior and error handling
- Backoff policy implementation
- Controller logic 
- Model serialization/deserialization
- UI state management

To run unit tests:
1. Select the SensiboToggle target in Xcode
2. Product → Test (or press Cmd+U)

### End-to-End Tests
The app includes UI tests that verify:
- Device list display and refresh behavior
- Toggle functionality 
- Temperature adjustment
- Error state handling

UI tests can be run alongside unit tests or individually.

## Performance Optimizations Details

### Optimistic Updates Implementation
The `ACController` implements optimistic updates for better perceived performance:
1. UI immediately reflects user actions
2. API call sent in background
3. Successful completion updates UI with server data
4. API failure rolls back UI changes automatically

### Retry Logic
Built-in retry mechanism with exponential backoff:
- Handles HTTP 429 (rate limiting) responses
- Automatically retries failed requests
- Prevents overwhelming the API with rapid retries

### Connection Pre-warming
The `warmup()` method in `ACController` pre-loads connections to improve responsiveness of subsequent operations.

### Mock Mode
For development and testing:
- Enables fast loading without network dependency
- Provides deterministic test data
- Allows UI testing without API calls
