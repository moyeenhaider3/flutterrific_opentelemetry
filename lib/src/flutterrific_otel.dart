// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutterrific_opentelemetry/src/common/otel_lifecycle_observer.dart';
import 'package:flutterrific_opentelemetry/src/factory/otel_flutter_factory.dart';
import 'package:flutterrific_opentelemetry/src/metrics/otel_metrics_bridge.dart';
import 'package:flutterrific_opentelemetry/src/metrics/ui_meter.dart';
import 'package:flutterrific_opentelemetry/src/metrics/ui_meter_provider.dart';
import 'package:flutterrific_opentelemetry/src/nav/otel_navigator_observer.dart';
import 'package:flutterrific_opentelemetry/src/trace/interaction_tracker.dart';
import 'package:flutterrific_opentelemetry/src/trace/ui_tracer.dart';
import 'package:flutterrific_opentelemetry/src/trace/ui_tracer_provider.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:uuid/uuid.dart';

import 'metrics/metrics_service.dart';

typedef CommonAttributesFunction = Attributes Function();

class FlutterOTel {
  static const defaultServiceName = "@dart/flutterrific_opentelemetry";
  static const defaultServiceVersion = "0.1.0";
  static const dartasticEndpoint = "https://otel.dartastic.io";

  static OTelLifecycleObserver? _lifecycleObserver;
  static OTelInteractionTracker? _interactionTracker;
  static OTelNavigatorObserver? _routeObserver;
  static final Map<String, sdk.Span> _activeSpans = <String, sdk.Span>{};
  static String? _appName;
  static CommonAttributesFunction? commonAttributesFunction;
  static String? appLaunchId;
  static Uint8List? currentAppLifecycleId;

  static OTelLifecycleObserver get lifecycleObserver =>
      _lifecycleObserver ??= OTelLifecycleObserver();

  static OTelInteractionTracker get interactionTracker =>
      _interactionTracker ??= OTelInteractionTracker();

  static OTelNavigatorObserver get routeObserver {
    if (_routeObserver == null) {
      throw StateError('FlutterOTel.initialize() must be called first.');
    }
    return _routeObserver!;
  }

  static String get appName {
    if (_appName == null) {
      throw StateError('FlutterOTel.initialize() must be called first.');
    }
    return _appName!;
  }

  static Future<void> initialize({
    String? appName,
    String? endpoint,
    bool secure = true,
    String serviceName = defaultServiceName,
    String? serviceVersion = defaultServiceVersion,
    String? tracerName,
    String? tracerVersion,
    Attributes? resourceAttributes,
    CommonAttributesFunction? commonAttributesFunction,
    sdk.SpanProcessor? spanProcessor,
    sdk.Sampler? sampler,
    SpanKind spanKind = SpanKind.client,
    String? dartasticApiKey,
    String? tenantId,
    Duration? flushTracesInterval = const Duration(seconds: 30),
    bool detectPlatformResources = true,
    MetricExporter? metricExporter,
    MetricReader? metricReader,
    bool enableMetrics = true,
    Map<String, String>? otelHeaders,
  }) async {
    _appName = appName ?? serviceName;
    FlutterOTel.commonAttributesFunction = commonAttributesFunction;

    if (endpoint == null) {
      final envEndpoint = const String.fromEnvironment(
        'OTEL_EXPORTER_OTLP_ENDPOINT',
      );
      if (envEndpoint.isNotEmpty) {
        endpoint = envEndpoint;
      } else if (dartasticApiKey != null && dartasticApiKey.isNotEmpty) {
        endpoint = dartasticEndpoint;
      } else {
        endpoint = OTelFactory.defaultEndpoint;
      }
    }

    resourceAttributes ??= sdk.OTel.attributes();
    appLaunchId = Uuid().v4();
    resourceAttributes = resourceAttributes.copyWithAttributes(
      <String, Object>{AppLifecycleSemantics.appLaunchId.key: appLaunchId!}.toAttributes(),
    );

    // Span processor setup
    if (spanProcessor == null) {
      sdk.SpanExporter exporter;
      if (kIsWeb) {
        exporter = OtlpHttpSpanExporter(
          OtlpHttpExporterConfig(
            endpoint: endpoint,
            headers: otelHeaders,
            compression: false,
          ),
        );
      } else {
        exporter = OtlpGrpcSpanExporter(
          OtlpGrpcExporterConfig(
            endpoint: endpoint,
            insecure: !secure,
            headers: otelHeaders,
          ),
        );
      }

      spanProcessor = sdk.BatchSpanProcessor(
        exporter,
        const BatchSpanProcessorConfig(
          maxQueueSize: 2048,
          scheduleDelay: Duration(seconds: 1),
          maxExportBatchSize: 512,
        ),
      );
    }

    // Metric exporter setup
    if (metricExporter == null) {
      if (kIsWeb) {
        metricExporter = OtlpHttpMetricExporter(
          OtlpHttpMetricExporterConfig(
            endpoint: endpoint,
            headers: otelHeaders,
            compression: false,
          ),
        );
      } else {
        metricExporter = OtlpGrpcMetricExporter(
          OtlpGrpcMetricExporterConfig(
            endpoint: endpoint,
            insecure: !secure,
            headers: otelHeaders,
          ),
        );
      }
    }

    metricReader ??= PeriodicExportingMetricReader(
      metricExporter,
      interval: const Duration(seconds: 1),
    );

    await sdk.OTel.initialize(
      endpoint: endpoint,
      secure: secure,
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      tracerName: tracerName,
      tracerVersion: tracerVersion,
      resourceAttributes: resourceAttributes,
      spanProcessor: spanProcessor,
      sampler: sampler ?? AlwaysOnSampler(),
      spanKind: spanKind,
      metricExporter: metricExporter,
      metricReader: metricReader,
      enableMetrics: enableMetrics,
      dartasticApiKey: dartasticApiKey,
      tenantId: tenantId,
      detectPlatformResources: detectPlatformResources,
      oTelFactoryCreationFunction: otelFlutterFactoryFactoryFunction,
    );

    _lifecycleObserver = OTelLifecycleObserver();
    _routeObserver = OTelNavigatorObserver();
    _interactionTracker = OTelInteractionTracker();

    WidgetsBinding.instance.addObserver(_lifecycleObserver!);

    OTelMetricsBridge.instance.initialize();

    if (kDebugMode) MetricsService.debugPrintMetricsStatus();

    if (flushTracesInterval != null) {
      Timer.periodic(flushTracesInterval, (_) {
        sdk.OTel.tracerProvider().forceFlush();
      });
    }
  }

  static UITracer get tracer => sdk.OTel.tracer() as UITracer;
  static UITracerProvider get tracerProvider => sdk.OTel.tracerProvider() as UITracerProvider;

  static UIMeterProvider get meterProvider => sdk.OTel.meterProvider() as UIMeterProvider;

  static UIMeter meter({String name = 'flutter.default', String? version, String? schemaUrl}) =>
      meterProvider.getMeter(name: name, version: version, schemaUrl: schemaUrl) as UIMeter;

  sdk.Span startScreenSpan(String screenName, {bool root = false, bool childRoute = false, Attributes? attributes, List<SpanLink>? spanLinks}) {
    if (root && childRoute) throw ArgumentError('root cannot be a child route');
    if (!childRoute) endScreenSpan(screenName);
    final span = tracer.startSpan(
      'screen.$screenName',
      kind: SpanKind.client,
      attributes: {'ui.screen.name': screenName, 'ui.type': 'screen'}.toAttributes(),
    );
    _activeSpans[screenName] = span;
    return span;
  }

  void endScreenSpan(String screenName) {
    final span = _activeSpans[screenName];
    if (span != null) {
      span.end();
      _activeSpans.remove(screenName);
    }
  }

  void recordUserInteraction(String screenName, String interactionType,
      {String? targetName, Duration? responseTime, Map<String, dynamic>? attributes}) {
    if (!tracer.enabled) return;
    final interactionAttributes = <String, Object>{
      'ui.screen.name': screenName,
      'ui.interaction.type': interactionType,
      if (targetName != null) 'ui.interaction.target': targetName,
      if (responseTime != null) 'ui.interaction.response_time_ms': responseTime.inMilliseconds,
      ...?attributes,
    };
    final span = tracer.startSpan(
      'interaction.$screenName.$interactionType',
      kind: SpanKind.client,
      attributes: interactionAttributes.toAttributes(),
    );
    if (responseTime != null) {
      span.end(endTime: span.startTime.add(responseTime));
      meter(name: 'flutter.interaction')
          .createHistogram(name: 'interaction.response_time', description: 'User interaction response time', unit: 'ms')
          .record(responseTime.inMilliseconds, interactionAttributes.toAttributes());
    } else {
      span.end();
      meter(name: 'flutter.interaction')
          .createCounter(name: 'interaction.count', description: 'User interaction count', unit: '{interactions}')
          .add(1, interactionAttributes.toAttributes());
    }
  }

  void recordNavigation(String fromRoute, String toRoute, String navigationType, Duration duration) {
    final navAttributes = {
      'ui.navigation.from': fromRoute,
      'ui.navigation.to': toRoute,
      'ui.navigation.type': navigationType,
    };
    final span = tracer.startSpan('navigation.$navigationType', kind: SpanKind.client, attributes: navAttributes.toAttributes());
    span.end(endTime: span.startTime.add(duration));
    meter(name: 'flutter.navigation')
        .createHistogram(name: 'navigation.duration', description: 'Navigation transition time', unit: 'ms')
        .record(duration.inMilliseconds, navAttributes.toAttributes());
  }

  static void reportError(String message, dynamic error, StackTrace? stackTrace, {Map<String, dynamic>? attributes}) {
    if (!tracer.enabled) return;
    final errorAttributes = <String, Object>{
      'error.context': message,
      'error.type': error.runtimeType.toString(),
      'error.message': error.toString(),
      ...?attributes,
    };
    final span = tracer.startSpan('error.$message', kind: SpanKind.client, attributes: errorAttributes.toAttributes());
    span.recordException(error, stackTrace: stackTrace, escaped: true);
    span.setStatus(SpanStatusCode.Error, error.toString());
    span.end();
    meter(name: 'flutter.errors')
        .createCounter(name: 'error.count', description: 'Error counter', unit: '{errors}')
        .add(1, errorAttributes.toAttributes());
  }

  void recordPerformanceMetric(String name, Duration duration, {Map<String, dynamic>? attributes}) {
    final span = tracer.startSpan(
      'perf.$name',
      kind: SpanKind.client,
      attributes: <String, Object>{'perf.metric.name': name, 'perf.duration_ms': duration.inMilliseconds, ...?attributes}.toAttributes(),
    );
    span.end(endTime: span.startTime.add(duration));
    meter(name: 'flutter.performance')
        .createHistogram(name: 'perf.$name', description: 'Performance measurement for $name', unit: 'ms')
        .record(duration.inMilliseconds, <String, Object>{'perf.metric.name': name, ...?attributes}.toAttributes());
  }

  void dispose() {
    _lifecycleObserver?.dispose();
    forceFlush();
  }

  static forceFlush() => tracerProvider.forceFlush();

  @visibleForTesting
  static reset() {
    sdk.OTel.reset();
    try {
      WidgetsBinding.instance.removeObserver(FlutterOTel.lifecycleObserver);
    } catch (_) {}
  }
}

extension OTelWidgetExtension on Widget {
  Widget withOTelErrorBoundary(String context) {
    return Builder(
      builder: (buildContext) {
        ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
          final tracer = FlutterOTel.tracer;
          String widgetName = errorDetails.context?.runtimeType.toString() ?? 'Unknown';
          tracer.recordError(context, errorDetails.exception, errorDetails.stack,
              attributes: {'error.context': 'widget_build', 'error.widget': widgetName});
          return ErrorWidget(errorDetails.exception);
        };
        return this;
      },
    );
  }
}
