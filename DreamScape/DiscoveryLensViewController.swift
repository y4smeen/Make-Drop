//
//  DiscoveryLensViewController.swift
//  DreamScape
//
//  Created by mjhowell on 12/26/16.
//  Copyright © 2016 Morgan. All rights reserved.
//

import UIKit
import MobileCoreServices
import AVFoundation
import SceneKit
import CoreMotion

//TODO: size of the scene's frame is interfering with the swipe gestures

class DiscoveryLensViewController: UIViewController {
    
    //initially contains no discovered shapes, however shapes will eventually populate according to user proximity
    //struct for now because of server spoofing, once the API calls can be made, this below should be an instance variable
   //static var discoveryLensModel: DiscoveryLensModel = DiscoveryLensModel()
    
    
    //session feed state and AR overlay scene
    var captureSession = AVCaptureSession()
    var sessionOutput = AVCapturePhotoOutput()
    var previewLayer = AVCaptureVideoPreviewLayer()
    var cameraViewCreated = false
    var currentNodesInFOV = Set<Int>()
    
    //core motion state
    var motionManager: CMMotionManager = CMMotionManager()
    var motionDisplayLink: CADisplayLink?
    var motionLastYaw: Float?
    var motionQueue: OperationQueue = OperationQueue()
    
    //timer state for async pinging of the MakeDrop Discovery API
    private let kTimeoutInSeconds:TimeInterval = Constants.PING_DISCOVERY_API_INTERVAL
    private var timer: Timer?
    private var lastRequestReturned = true
    
    //Discovery lens model, which holds all scene kit node states as well as all shapes in current field of view

    //camera node that should align with the video feed and approximate user movement adjustments
    var discoveryLensModel: DiscoveryLensModel?
    
    
    @IBOutlet var discoverySuperView: UIView! {
        didSet {
            
            //set gestures for tab view control
            let swipeLeftGesture = UISwipeGestureRecognizer (
                target: self,
                action: #selector(DiscoveryLensViewController.tabRight(_:))
            )
            swipeLeftGesture.direction = .left
            discoverySuperView.addGestureRecognizer(swipeLeftGesture)
            
            let swipeRightGesture = UISwipeGestureRecognizer (
                target: self,
                action: #selector(DiscoveryLensViewController.tabLeft(_:))
            )
            swipeRightGesture.direction = .right
            discoverySuperView.addGestureRecognizer(swipeRightGesture)
        }
    }
    
    
    @IBOutlet weak var cameraView: CameraDiscoveryLensView!
    
    func tabLeft(_ swipeRight: UISwipeGestureRecognizer) {
        self.tabBarController?.selectedIndex -= 1
    }
    
    func tabRight(_ swipeLeft: UISwipeGestureRecognizer) {
        self.tabBarController?.selectedIndex += 1
    }
    
    func motionRefresh(gyroData: CMGyroData?, hasError error: Error?) {
        print(gyroData?.rotationRate.y ?? 0.0)
    }
    
    
    //convert from the core motion reference frame to the scene kit's reference frame
    func orientationFromCMQuaternion(q: CMQuaternion) -> SCNQuaternion {
        let gq1: GLKQuaternion =  GLKQuaternionMakeWithAngleAndAxis(GLKMathDegreesToRadians(-90), 1, 0, 0) // add a rotation of the pitch 90 degrees
        let gq2: GLKQuaternion =  GLKQuaternionMake(Float(q.x), Float(q.y), Float(q.z), Float(q.w)) // the current orientation
        let qp: GLKQuaternion  =  GLKQuaternionMultiply(gq1, gq2) // get the "new" orientation
        let rq: CMQuaternion =   CMQuaternion(x: Double(qp.x), y: Double(qp.y), z: Double(qp.z), w: Double(qp.w))
        return SCNVector4Make(Float(rq.x), Float(rq.y), Float(rq.z), Float(rq.w));
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        discoveryLensModel =  DiscoveryLensModel(scene: createARFieldOfView())
        startSceneKitReferenceConversion()
    }
    
    //synchronize the scenekit overlay with the camera feed to stabilize 3d models and give AR effect
    func startSceneKitReferenceConversion() {
        self.motionManager.startDeviceMotionUpdates(to: motionQueue) {
            [weak self] (motion: CMDeviceMotion?, error: Error?) in
            let attitude: CMAttitude = motion!.attitude
            //lock scene kit mutex
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            let quaternion: SCNQuaternion = self!.orientationFromCMQuaternion(q: attitude.quaternion)
            self?.discoveryLensModel?.cameraNode?.orientation = quaternion
            SCNTransaction.commit()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if cameraViewCreated {
            captureSession.startRunning()
        } else {
            startCameraViewOverlaySession()
            cameraViewCreated = true
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !Constants.SPOOF_SERVER {
            startFetching()
        }
        //tab bar item appearance under this specific controller
        self.tabBarController?.tabBar.tintColor = UIColor(
            colorLiteralRed: Constants.DEFAULT_BLUE[0],
            green: Constants.DEFAULT_BLUE[1],
            blue: Constants.DEFAULT_BLUE[2],
            alpha: Constants.DEFAULT_BLUE[3])
        self.tabBarController?.tabBar.unselectedItemTintColor = UIColor.white
        

    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureSession.stopRunning()
        if !Constants.SPOOF_SERVER {
            stopFetching()
        }
    }

    //initializing the feed session and affixing it as a sublayer of the CameraDiscoveryLensView layer
    func startCameraViewOverlaySession() {
        let deviceSession = AVCaptureDeviceDiscoverySession(deviceTypes: [.builtInDualCamera,.builtInTelephotoCamera,.builtInWideAngleCamera], mediaType: AVMediaTypeVideo, position: .unspecified)
        
        for device in (deviceSession?.devices)! {
            
            if device.position == AVCaptureDevicePosition.back {
                
                do {

                    let input = try AVCaptureDeviceInput(device: device)
                    
                    if captureSession.canAddInput(input){
                        captureSession.addInput(input)
                        
                        if captureSession.canAddOutput(sessionOutput){
                            captureSession.addOutput(sessionOutput)
                            previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                            previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
                            previewLayer.connection.videoOrientation = .portrait
                            cameraView.layer.addSublayer(previewLayer)
                            previewLayer.position = CGPoint (x: self.cameraView.frame.width / 2, y: self.cameraView.frame.height / 2)
                            previewLayer.bounds = cameraView.frame
                            captureSession.startRunning()
                        }
                    }
                    
                } catch let avError { print(avError)}
            }
        }
    }
    
    
    func createARFieldOfView() -> SCNView {
        let sceneView = SCNView()
        sceneView.frame = self.view.bounds
        sceneView.backgroundColor = UIColor.clear
        sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = true //in the future, we may want to disable this in discovery mode
        self.view.addSubview(sceneView)
        
        if Constants.DEBUG_MODE && Constants.SPOOF_SERVER && discoveryLensModel != nil &&
            discoveryLensModel!.hasShapesInFieldOfView() {
            //under debugging and server spoof mode, we simply load the shape that is currently in the editor
            print("DEBUG INFO- Cube loaded from Canvas Editor")
            sceneView.scene = discoveryLensModel!.sceneView.scene
        //loads blank stub shape
        } else if Constants.DEBUG_MODE && Constants.SPOOF_SERVER {
            print("DEBUG INFO- Stub cube loaded into camera view")
            //testing default cube with images affixed as materials
            var images: [UIImage] = Array()
            images.append(UIImage(named: "AR_Sample")!)
            images.append(UIImage(named: "AR_Sample2")!)
            sceneView.scene = DiscoveryScene(scale: 1.0, withShape: Constants.Shape.Cube, withImages: images)
        } else {
            sceneView.scene = DiscoveryScene()
            self.view.addSubview(sceneView)
        }
        
        return sceneView
    }
    
    //link nodes from scene blueprint to Discovery Lens Controller
//    public static func addDiscoveredShapeNode(shape: SCNNode) {
//        if(Constants.DEBUG_MODE && Constants.SPOOF_SERVER) {
//            if DiscoveryLensViewController.discoveredShapes == nil {
//                DiscoveryLensViewController.discoveredShapes = Array()
//            }
//            DiscoveryLensViewController.discoveredShapes?.append(shape)
//        }
//    }
    
//    public static func addCameraNode(camera: SCNNode) {
//        if(Constants.DEBUG_MODE && Constants.SPOOF_SERVER) {
//            DiscoveryLensViewController.sceneKitCamera = camera
//        }
//    }
//    
    
    func formProximityRequest() -> NSMutableURLRequest {
        let jsonBody: Dictionary<String, String> = ["lat": GlobalResources.Location.lat ,
                                                    "long": GlobalResources.Location.long]
        var jsonData: Data?
        do {
            jsonData = try JSONSerialization.data(withJSONObject: jsonBody, options: .prettyPrinted)
        } catch {
            print("ERROR - Formatting JSON for drop request")
        }
        
        if(Constants.DEBUG_MODE) {
            Constants.printJSONDataReadable(json: jsonData, to: Constants.DISCOVER_SHAPES_ENDPOINT)
        }
        
        let url: URL = NSURL(string: Constants.DISCOVER_SHAPES_ENDPOINT)! as URL
        let request = NSMutableURLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        return request
    }
    
    
    
    //Given a discovery payload, we attempt to return a dictionary that represents the preassembled shape information
    func parseJSONPayloadToDict(data: Any?) -> NSDictionary? {
        
        do {
            let convertedData =  try JSONSerialization.data(withJSONObject: data!, options: .prettyPrinted) // first of all convert json to the data
            let text = String(data: convertedData , encoding: .utf8) // the data will be converted to the string
            if let unwrappedData = text {
                if let jsonData = unwrappedData.data(using: .utf8) {
                    if let shapeData = try? JSONSerialization.jsonObject(with: jsonData,
                                                                      options: JSONSerialization.ReadingOptions.mutableContainers) {
                        if let shapeDict = shapeData as? NSDictionary, shapeDict.count > 0 {
                            return Optional(shapeDict)
                        } else {
                            if(Constants.DEBUG_MODE) {
                                print("No new shapes were found, response was empty")
                            }
                        }
                    } else {
                        print("ERROR - could not convert discovery data json to NSDict")
                    }
                } else {
                    print("ERROR - could not convert discovery data payload string to json")
                }
            } else {
                print("ERROR- Could not convert discovery payload to string")
            }
            
        } catch let jsonError {
            print("ERROR PARSING DISCOVERY JSON- \(jsonError)")
        }
        
        return nil
    }
    
    //Requesting the MakeDrop Discovery API to send nearby shapes
    func requestProximity() {
        if lastRequestReturned {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                //We are accessing a shared context below, but it is OK if multiple threads enter the critical region below
                //we simply need some sort of throttle in case the network requests take more time than intended
                self?.lastRequestReturned = false
                if let request = self?.formProximityRequest() {
                    let task = URLSession.shared.dataTask(with: request as URLRequest) { data,response,error in
                        if error != nil{
                            print("ERROR- \(error?.localizedDescription)")
                            return
                        }
                        do {
                            let response = try JSONSerialization.jsonObject(with: data!,
                                                                            options: JSONSerialization.ReadingOptions.mutableContainers)
                            if let parsedResponse = response as? NSDictionary {
                                if let status = parsedResponse["status"] as? String {
                                    if(status == "success") {
                                        //successful response from the Discovery API
                                        if let payload = self?.parseJSONPayloadToDict(data: parsedResponse["data"]) {
                                            //main helper method for assembling shapes from the JSON Discovery response
                                            if(Constants.DEBUG_MODE) {
                                                print("CUBE FOUND: attempting to construct shape from API response")
                                                //print("DATA:\n \(payload)")
                                            }
                                            self?.assembleShapeResponseInView(response: payload)
                                        }
                                    } else {
                                        print("ERROR- From Discovery API: \(parsedResponse["reason"] as? String)")
                                    }
                                } else {
                                    print("ERROR- Could not understand Discovery API response")
                                }
                            } else {
                                print("ERROR- Could not parse Discovery API JSON response to NSDictionary")
                            }
                        } catch {
                            print("ERROR - Failed to ping the discovery APIs for nearby objects")
                        }
                    }
                    task.resume()
                }
                self?.lastRequestReturned = true
            }
        }
    }
    
    private func scrapeShapeType(shape discoveredShape: NSDictionary) -> Constants.Shape {
        var shapeName: String = Constants.DEFAULT_SHAPE_NAME
        if discoveredShape["name"] is String  {
            if let s = discoveredShape["name"] as? String {
                shapeName = s
            }
        }
        return Constants.Shape(rawValue: shapeName) ?? Constants.DEFAULT_SHAPE_TYPE
    }
    
    private func scrapeScale(shape discoveredShape: NSDictionary) -> CGFloat {
        var shapeScale: CGFloat
        if let scaleFloat = discoveredShape["scale"] as? Float {
            shapeScale = CGFloat(scaleFloat)
        } else {
            shapeScale = Constants.DEFAULT_SHAPE_SCALE
        }
        return shapeScale
    }
    
    
    private func scrapeMaterialImages(shape discoveredShape: NSDictionary) -> [UIImage] {
        var materials : [UIImage] = Array()
        if let materialsJSONDict = parseJSONPayloadToDict(data: discoveredShape["materials"]) {
            for i in 0..<materialsJSONDict.count {
                if let base64Data = materialsJSONDict["\(i)"] as? String {
                    if let decodedString = Data.init(base64Encoded: base64Data,
                                                     options: .ignoreUnknownCharacters) {
                        if let image = UIImage(data: decodedString) {
                            materials.append(image)
                        } else {
                           print("ERROR - unable to convert the decoded base64 string from the Discovery API response to a UIImage")
                        }
                    } else {
                        print("ERROR - unable to decode the base64 material image data from the Discovery API response")
                    }
                } else {
                    print("ERROR - unable to retrieve the base64 string from Discovery's material response")
                }
            }
        }
        return materials
    }
    
    private func scrapeID(shape discoveredShape: NSDictionary) -> Int? {
        var shapeID: Int?
        if let idPayload = discoveredShape["id"] as? Int {
            shapeID = idPayload
            
        }
        return shapeID
    }
    
    //convert each discovered shape from the Discovery API response to a shape with it's corresponding materials in the model
    func assembleShapeResponseInView(response: NSDictionary) {
        print("DICT: \(response)")
        for (_, shapeMetaData) in response {
            if let discoveredShape = parseJSONPayloadToDict(data: shapeMetaData) {
                if let shapeInfoJSONDict = parseJSONPayloadToDict(data: discoveredShape["shape"]) {
                    print("METADATA: \(shapeInfoJSONDict)")
                    let type = scrapeShapeType(shape: shapeInfoJSONDict)
                    let scale = scrapeScale(shape: shapeInfoJSONDict)
                    let id = scrapeID(shape: shapeInfoJSONDict)
                    print("ID: \(id)")
                    let materialImages = scrapeMaterialImages(shape: discoveredShape)
                    let assembledShape = Constants.filledStructure(shape: type,
                                                                   ofScale: scale,
                                                                   ofID: id,
                                                                   withImages: materialImages)
                    //notify thread dedicated to UI that model has updated shapes if new shapes
                    //have been discovered
                    DispatchQueue.main.async { [weak self] in
                        self?.discoveryLensModel?.addShapeToFieldOfView(shape: assembledShape)
                    }
                } else {
                    print("ERROR- could not parse discovery API response shape metadata")
                }
            } else {
                print("ERROR - parsing one or more of the given shapes in the Discovery API JSON response")
            }
        }
    }
    
    //initiate discovery mode, which pings the MakeDrop API for nearby shapes
    func startFetching() {
        self.timer = Timer.scheduledTimer(timeInterval: self.kTimeoutInSeconds,
                                          target: self,
                                          selector: #selector(DiscoveryLensViewController.requestProximity),
                                          userInfo: nil,
                                          repeats: true)
    }
    
    func stopFetching() {
        self.timer!.invalidate()
    }
    
    //only used for server spoof mode to load shapes in from the Canvas Editor's model
    //communication of this form is not proper and will be deleted once the server-side code is written
//    public static func updateModel(discoveryLensModel: DiscoveryLensModel) {
//        if Constants.DEBUG_MODE && Constants.SPOOF_SERVER {
//            DiscoveryLensViewController.discoveryLensModel = discoveryLensModel
//        } else {
//            print("Error- This model to model communication is not permitted")
//        }
//    }
    
    
    
}
