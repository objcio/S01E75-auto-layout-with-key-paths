//
//  ViewController.swift
//  Laufpark
//
//  Created by Chris Eidhof on 07.09.17.
//  Copyright © 2017 objc.io. All rights reserved.
//

import UIKit
import MapKit
import Incremental

final class TargetAction {
    let handler: () -> ()
    init(_ handler: @escaping () -> ()) {
        self.handler = handler
    }
    @objc func action() {
        handler()
    }
}

final class Box<A> {
    let unbox: A
    var references: [Any] = []
    
    init(_ value: A) {
        self.unbox = value
    }
}

extension Box where A: UIControl {
    func handle(_ events: UIControlEvents, handler: @escaping () -> ()) {
        let target = TargetAction(handler)
        references.append(target)
        unbox.addTarget(target, action: #selector(TargetAction.action), for: events)
    }
}

extension Box where A: UIActivityIndicatorView {
    func bindIsAnimating(to isAnimating: I<Bool>) {
        let disposable = isAnimating.observe { [unowned self] isLoading in
            if isLoading {
                self.unbox.startAnimating()
            } else {
                self.unbox.stopAnimating()
            }
        }
        references.append(disposable)
    }
}

extension UIView {
    func addSubview(_ other: UIView, constraints: [Constraint]) {
        addSubview(other)
        other.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(constraints.map { c in
            c(other, self)
        })

    }
}

extension Box where A: UIView {
    func addSubview<V: UIView>(_ view: Box<V>, constraints: [Constraint]) {
        unbox.addSubview(view.unbox, constraints: constraints)
        references.append(view)
    }

    func addConstraint(_ constraint: Box<NSLayoutConstraint>) {
        references.append(constraint)
    }
}

typealias Constraint = (_ child: UIView, _ parent: UIView) -> NSLayoutConstraint

func equal<L, Axis>(_ to: KeyPath<UIView, L>) -> Constraint where L: NSLayoutAnchor<Axis> {
    return { view, parent in
        view[keyPath: to].constraint(equalTo: parent[keyPath: to])
    }
}

func equal<L>(_ keyPath: KeyPath<UIView, L>, to constant: CGFloat) -> Constraint where L: NSLayoutDimension {
    return { view, parent in
        view[keyPath: keyPath].constraint(equalToConstant: constant)
    }
}

func equal<L, Axis>(_ from: KeyPath<UIView, L>, _ to: KeyPath<UIView, L>) -> Constraint where L: NSLayoutAnchor<Axis> {
    return { view, parent in
        view[keyPath: from].constraint(equalTo: parent[keyPath: to])
    }
}

extension Box {
    func bind<Property>(_ keyPath: ReferenceWritableKeyPath<A, Property>, to value: I<Property>) {
        references.append(value.observe { [unowned self] newValue in
            self.unbox[keyPath: keyPath] = newValue
        })
    }
}


struct State: Equatable {
    var tracks: [Track]
    var loading: Bool { return tracks.isEmpty }
    var satellite: Bool = false
    
    var selection: MKPolygon? {
        didSet {
            trackPosition = nil
        }
    }
 
    var trackPosition: CGFloat? // 0...1
    
    var hasSelection: Bool { return selection != nil }
    
    init(tracks: [Track]) {
        selection = nil
        trackPosition = nil
        self.tracks = tracks
    }
    
    static func ==(lhs: State, rhs: State) -> Bool {
        return lhs.selection == rhs.selection && lhs.trackPosition == rhs.trackPosition && lhs.tracks == rhs.tracks && lhs.satellite == rhs.satellite
    }
}

final class ViewController: UIViewController {
    private let mapView = Box(buildMapView())
    private var _mapView: MKMapView { return mapView.unbox }
    private let positionAnnotation = MKPointAnnotation()
    private let trackInfoView = TrackInfoView()
    

    private var stateInput: Input<State> = Input(State(tracks: []))
    private var state: I<State> {
        return stateInput.i
    }
    private var _state: State = State(tracks: []) {
        didSet {
            stateInput.write(_state)
            update(old: oldValue)
        }
    }

    private var polygons: [MKPolygon: Track] = [:]
    private var locationManager: CLLocationManager?
    private var rootView: Box<UIView>!

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError()
    }

    func setTracks(_ t: [Track]) {
        _state.tracks = t
    }
    
    override func viewDidLoad() {
        view.backgroundColor = .white
        rootView = Box(view)

        // Configuration
        _mapView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(mapTapped(sender:))))
        _mapView.addAnnotation(positionAnnotation)
        trackInfoView.panGestureRecognizer.addTarget(self, action: #selector(didPanProfile))

        // Layout
        view.addSubview(_mapView)
        _mapView.translatesAutoresizingMaskIntoConstraints = false
        _mapView.addConstraintsToSizeToParent()
        _mapView.delegate = self
        mapView.bind(\.mapType, to: state.map { $0.satellite ? .satellite : .standard })

        let trackInfoBox = Box(trackInfoView)
        trackInfoBox.bind(\.darkMode, to: state.map { $0.satellite })
        let trackInfoViewHeight: CGFloat = 120
        rootView.addSubview(trackInfoBox, constraints: [
            equal(\.leftAnchor),
            equal(\.rightAnchor),
            equal(\.heightAnchor, to: trackInfoViewHeight)
        ])
        let trackInfoConstraint = trackInfoView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: trackInfoViewHeight)
        trackInfoConstraint.isActive = true
        let trackInfoConstraintBox = Box(trackInfoConstraint)
        trackInfoConstraintBox.bind(\.constant, to: state.map { $0.hasSelection ? 0 : trackInfoViewHeight })
        trackInfoBox.addConstraint(trackInfoConstraintBox)

        let loadingIndicator = UIActivityIndicatorView(activityIndicatorStyle: .gray)
        loadingIndicator.hidesWhenStopped = true
        let box = Box(loadingIndicator)
        box.bindIsAnimating(to: state.map { $0.loading })
        rootView.addSubview(box, constraints: [
            equal(\.centerXAnchor),
            equal(\.centerYAnchor)
        ])
        
        let button = UIButton(type: .system)
        let boxedButton = Box(button)
        button.setTitle("Toggle", for: .normal)
        boxedButton.handle(.touchUpInside) { [unowned self] in
            self._state.satellite = !self._state.satellite
        }
        mapView.addSubview(boxedButton, constraints: [
            equal(\.topAnchor, \.safeAreaLayoutGuide.topAnchor),
            equal(\.trailingAnchor, \.safeAreaLayoutGuide.trailingAnchor)
        ])
    }
    
    override func viewDidAppear(_ animated: Bool) {
        resetMapRect()
        if CLLocationManager.authorizationStatus() == .notDetermined {
            locationManager = CLLocationManager()
            locationManager!.requestWhenInUseAuthorization()
        }
    }
    
    private func update(old: State) {
        if _state.tracks != old.tracks {
            _mapView.removeOverlays(_mapView.overlays)
            for track in _state.tracks {
                let polygon = track.polygon
                polygons[polygon] = track
                _mapView.add(polygon)
            }
        }
        if _state.selection != old.selection {
            for polygon in polygons.keys {
                guard let renderer = _mapView.renderer(for: polygon) as? MKPolygonRenderer else { continue }
                renderer.configure(color: polygons[polygon]!.color.uiColor, selected: !_state.hasSelection)
            }
            if let selectedPolygon = _state.selection, let renderer = _mapView.renderer(for: selectedPolygon) as? MKPolygonRenderer {
                renderer.configure(color: polygons[selectedPolygon]!.color.uiColor, selected: true)
            }
            trackInfoView.track = _state.selection.flatMap { polygons[$0] }
        }
        if _state.trackPosition != old.trackPosition {
            trackInfoView.position = _state.trackPosition
            if let position = _state.trackPosition, let selection = _state.selection, let track = polygons[selection] {
                let distance = Double(position) * track.distance
                if let point = track.point(at: distance) {
                    positionAnnotation.coordinate = point.coordinate
                }
            } else {
                positionAnnotation.coordinate = CLLocationCoordinate2D()
            }
        }
    }

    private func resetMapRect() {
        _mapView.setVisibleMapRect(MKMapRect(origin: MKMapPoint(x: 143758507.60971117, y: 86968700.835495561), size: MKMapSize(width: 437860.61378830671, height: 749836.27541357279)), edgePadding: UIEdgeInsetsMake(10, 10, 10, 10), animated: true)
    }
    
    override func motionEnded(_ motion: UIEventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        resetMapRect()
    }

    @objc func mapTapped(sender: UITapGestureRecognizer) {
        let point = sender.location(ofTouch: 0, in: _mapView)
        let mapPoint = MKMapPointForCoordinate(_mapView.convert(point, toCoordinateFrom: _mapView))
        let possibilities = polygons.keys.filter { polygon in
            guard let renderer = _mapView.renderer(for: polygon) as? MKPolygonRenderer else { return false }
            let point = renderer.point(for: mapPoint)
            return renderer.path.contains(point)
        }
        
        // in case of multiple matches, toggle between the selections, and start out with the smallest route
        if let s = _state.selection, possibilities.count > 1 && possibilities.contains(s) {
            _state.selection = possibilities.lazy.sorted { $0.pointCount < $1.pointCount }.first(where: { $0 != s })
        } else {
            _state.selection = possibilities.first
        }
    }
    
    @objc func didPanProfile(sender: UIPanGestureRecognizer) {
        let normalizedPosition = (sender.location(in: trackInfoView).x / trackInfoView.bounds.size.width).clamped(to: 0.0...1.0)
        _state.trackPosition = normalizedPosition
    }
}


extension ViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer() }
        if let renderer = mapView.renderer(for: overlay) { return renderer }
        let renderer = MKPolygonRenderer(polygon: polygon)
        let isSelected = _state.selection == polygon
        renderer.configure(color: polygons[polygon]!.color.uiColor, selected: isSelected || !_state.hasSelection)
        return renderer
    }
    
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let pointAnnotation = annotation as? MKPointAnnotation, pointAnnotation == positionAnnotation else { return nil }
        let result = MKPinAnnotationView(annotation: annotation, reuseIdentifier: nil)
        result.pinTintColor = .red
        return result
    }
}


extension MKPolygonRenderer {
    func configure(color: UIColor, selected: Bool) {
        strokeColor = color
        fillColor = selected ? color.withAlphaComponent(0.2) : color.withAlphaComponent(0.1)
        lineWidth = selected ? 3 : 1
    }
}


